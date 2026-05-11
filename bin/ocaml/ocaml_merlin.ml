open Import

module Selected_context = struct
  let arg =
    let ctx_name_conv =
      let parse ctx_name =
        match Context_name.of_string_opt ctx_name with
        | None -> Error (`Msg (Printf.sprintf "Invalid context name %S" ctx_name))
        | Some ctx_name -> Ok ctx_name
      in
      let print ppf t = Stdlib.Format.fprintf ppf "%s" (Context_name.to_string t) in
      Arg.conv ~docv:"context" (parse, print)
    in
    Arg.(
      value
      & opt ctx_name_conv Context_name.default
      & info
          [ "context" ]
          ~docv:"CONTEXT"
          ~doc:
            (Some "Select the Dune build context that will be used to return information"))
  ;;
end

module Merlin = Dune_rules.Merlin

module Output_format = struct
  type t =
    [ `Text
    | `Json
    ]

  let all = [ "text", `Text; "json", `Json ]
end

module Server : sig
  val dump
    :  selected_context:Context_name.t
    -> format:Output_format.t
    -> string
    -> unit Fiber.t

  val dump_dot_merlin : selected_context:Context_name.t -> string -> unit Fiber.t

  (** Once started the server will wait for commands on stdin, read the
      requested merlin dot file and return its content on stdout. The server
      will halt when receiving EOF of a bad csexp. *)
  val start : selected_context:Context_name.t -> unit -> unit Fiber.t
end = struct
  open Fiber.O

  module Merlin_conf = struct
    type t = Sexp.t

    let make_error msg = Sexp.(List [ List [ Atom "ERROR"; Atom msg ] ])

    let to_stdout (t : t) =
      Csexp.to_channel stdout t;
      flush stdout
    ;;
  end

  module Commands = struct
    type t =
      | File of
          { path : string
          ; context : string option
          }
      | Halt
      | Unknown of string

    let read_input in_channel =
      match Csexp.input_opt in_channel with
      | Ok None -> Halt
      | Ok (Some sexp) ->
        let open Sexp in
        (match sexp with
         | Atom "Halt" -> Halt
         | List [ Atom "File"; Atom path ] -> File { path; context = None }
         | List [ Atom "File"; Atom path; Atom "Context"; Atom context ] ->
           File { path; context = Some context }
         | sexp ->
           let msg = Printf.sprintf "Bad input: %s" (Sexp.to_string sexp) in
           Unknown msg)
      | Error err ->
        Format.eprintf "Bad input: %s@." err;
        Halt
    ;;
  end

  (* [make_relative_to_root p] will check that [Path.root] is a prefix of the
     absolute path [p] and remove it if that is the case. Under Windows and
     Cygwin environment both paths are lowarcased before the comparison *)
  let make_relative_to_root p =
    let p = Path.to_absolute_filename p in
    let prefix = Path.(to_absolute_filename root) in
    (if Sys.win32 || Sys.cygwin then String.Caseless.drop_prefix else String.drop_prefix)
      ~prefix
      p
    (* After dropping the prefix we need to remove the leading path separator *)
    |> Option.map ~f:(fun s -> String.drop s 1)
  ;;

  (* Given a path [p] relative to the workspace root, [get_merlin_files_paths p]
     navigates to the [_build] directory and reaches this path from the correct
     context. Then it returns the list of available Merlin configurations for
     this directory. *)
  let get_merlin_files_paths dir =
    let merlin_path =
      Path.Build.relative dir Dune_rules.Merlin_ident.merlin_folder_name
    in
    Path.build merlin_path
    |> Path.readdir_unsorted
    |> Result.value ~default:[]
    |> List.sort ~compare:String.compare
    |> List.map ~f:(fun f -> Path.Build.relative merlin_path f |> Path.build)
  ;;

  module Merlin = Dune_rules.Merlin

  let no_config_found file =
    Path.Build.drop_build_context_exn file
    |> Path.Source.to_string_maybe_quoted
    |> Printf.sprintf "No config found for file %s. Try calling 'dune build'."
    |> Merlin_conf.make_error
  ;;

  let rec find_closest_processed path =
    match
      get_merlin_files_paths path
      |> List.find_map ~f:(fun file_path ->
        match Merlin.Processed.load_file file_path with
        | Ok config -> Some config
        | Error _ -> None)
    with
    | Some config -> Some config
    | None ->
      (match Path.Build.parent path with
       | None -> None
       | Some dir -> find_closest_processed dir)
  ;;

  let load_selected_context_merlin_config selected_context =
    get_merlin_files_paths (Context_name.build_dir selected_context)
    |> List.find_map ~f:(fun path ->
      match Merlin.Processed.load_file path with
      | Ok config -> Some config
      | Error _ -> None)
  ;;

  let load_context_merlin_config context =
    find_closest_processed (Path.Build.parent_exn context)
  ;;

  let find_nearest_dune_package file =
    let rec loop dir =
      let dune_package = Path.relative (Path.build dir) Dune_rules.Dune_package.fn in
      if Fpath.exists (Path.to_string dune_package)
      then Some dune_package
      else (
        match Path.Build.parent dir with
        | None -> None
        | Some dir -> loop dir)
    in
    loop (Path.Build.parent_exn file)
  ;;

  let load_external_package_config ~selected_context ~context file ~physical_file =
    let base =
      match context with
      | Some context -> load_context_merlin_config context
      | None -> load_selected_context_merlin_config selected_context
    in
    let config =
      match find_nearest_dune_package file with
      | None -> None
      | Some dune_package_path ->
        let package =
          Io.with_lexbuf_from_file dune_package_path ~f:(fun lexbuf ->
            Dune_rules.Dune_package.Or_meta.parse dune_package_path lexbuf)
        in
        (match package with
         | Error _ | Ok Dune_rules.Dune_package.Or_meta.Use_meta -> None
         | Ok (Dune_rules.Dune_package.Or_meta.Dune_package package) ->
           Merlin.Processed.get_external_package ~base package ~file)
    in
    Fiber.return
      (match config with
       | Some _ as config -> config
       | None -> Merlin.Processed.get_external_source_fallback ~base ~file ~physical_file)
  ;;

  let load_merlin_file ~selected_context ~context file ~physical_file =
    match find_closest_processed (Path.Build.parent_exn file) with
    | Some config ->
      (match Merlin.Processed.get config ~file with
       | Some config -> Fiber.return config
       | None ->
         load_external_package_config ~selected_context ~context file ~physical_file
         >>| Option.value ~default:(no_config_found file))
    | None ->
      load_external_package_config ~selected_context ~context file ~physical_file
      >>| Option.value ~default:(no_config_found file)
  ;;

  (* [to_local p] makes path [p] relative to the project's root. [p] can be: -
     An absolute path - A path relative to [Path.initial_cwd] *)
  let to_local file_path =
    let error msg = Error msg in
    (* This ensure the path is absolute. If not it is prefixed with
       [Path.initial_cwd] *)
    let abs_file_path = Path.of_filename_relative_to_initial_cwd file_path in
    (* Then we make the path relative to [Path.root] (and not
       [Path.initial_cwd]) *)
    match make_relative_to_root abs_file_path with
    | Some path ->
      (try
         let path = Path.of_string path in
         (* If dune ocaml-merlin is called from within the build dir we must
            remove the build context *)
         Ok (Path.drop_optional_build_context path |> Path.local_part)
       with
       | User_error.E mess -> User_message.to_string mess |> error)
    | None ->
      Printf.sprintf
        "Path %s is not in dune workspace (%s)."
        (String.maybe_quoted file_path)
        (String.maybe_quoted @@ Path.(to_absolute_filename Path.root))
      |> error
  ;;

  let resolve_context_name selected_context =
    match Dune_engine.Context_name.is_default selected_context with
    | false -> Fiber.return (Ok selected_context)
    | true ->
      let+ workspace = Memo.run (Workspace.workspace ()) in
      (match workspace.merlin_context with
       | None -> Error "no merlin context configured"
       | Some context -> Ok context)
  ;;

  let source_path_of_external_dependency context_name file =
    match Path.of_filename_relative_to_initial_cwd file |> Path.as_outside_build_dir with
    | Some (External external_path) ->
      Memo.run
        (Dune_rules.Pkg_rules.source_path_of_external_dependency
           context_name
           external_path)
    | Some (In_source_dir _) | None -> Fiber.return None
  ;;

  let to_local ~selected_context file =
    let open Fiber.O in
    let* context_name = resolve_context_name selected_context in
    match context_name with
    | Error _ as error -> Fiber.return error
    | Ok context_name ->
      (match to_local file with
       | Ok file ->
         Fiber.return
           (Ok (Path.Build.append_local (Context_name.build_dir context_name) file))
       | Error workspace_error ->
         let+ external_source_path =
           source_path_of_external_dependency context_name file
         in
         (match external_source_path with
          | Some path -> Ok path
          | None -> Error workspace_error))
  ;;

  let print_merlin_conf ~selected_context ~path ~context =
    let open Fiber.O in
    let physical_file =
      let path = Path.of_filename_relative_to_initial_cwd path in
      match Path.as_outside_build_dir path with
      | Some (External _) -> Some path
      | Some (In_source_dir _) | None -> None
    in
    let* context =
      match context with
      | None -> Fiber.return None
      | Some context ->
        to_local ~selected_context context
        >>| (function
         | Ok context -> Some context
         | Error _ -> None)
    in
    let* config =
      to_local ~selected_context path
      >>= function
      | Error s -> Fiber.return (Merlin_conf.make_error s)
      | Ok file -> load_merlin_file ~selected_context ~context file ~physical_file
    in
    Fiber.return (Merlin_conf.to_stdout config)
  ;;

  let dump ~selected_context ~format s =
    to_local ~selected_context s
    >>| function
    | Error mess -> Printf.eprintf "%s\n%!" mess
    | Ok path -> get_merlin_files_paths path |> Merlin.Processed.print_files format
  ;;

  let dump_dot_merlin ~selected_context s =
    to_local ~selected_context s
    >>| function
    | Error mess -> Printf.eprintf "%s\n%!" mess
    | Ok path ->
      let files = get_merlin_files_paths path in
      Merlin.Processed.print_generic_dot_merlin files
  ;;

  let start ~selected_context () =
    let open Fiber.O in
    let rec main () =
      match Commands.read_input stdin with
      | Halt -> Fiber.return ()
      | File { path; context } ->
        let* () = print_merlin_conf ~selected_context ~path ~context in
        main ()
      | Unknown msg ->
        Merlin_conf.to_stdout (Merlin_conf.make_error msg);
        main ()
    in
    main ()
  ;;
end

module Dump_config = struct
  let info =
    Cmd.info
      ~doc:
        "Print the entire content of the merlin configuration for the given folder in a \
         user friendly form. This is for testing and debugging purposes only and should \
         not be considered as a stable output."
      "dump-config"
  ;;

  let term =
    let+ builder = Common.Builder.term
    (* CR-someday Alizter: document this option *)
    and+ dir = Arg.(value & pos 0 dir "" & info [] ~docv:"PATH" ~doc:None)
    and+ format =
      Arg.(
        value
        & opt (enum Output_format.all) `Text
        & info [ "format" ] ~docv:"FORMAT" ~doc:(Some "Output format (text or json)."))
    and+ selected_context = Selected_context.arg in
    let _common, config =
      let builder =
        let builder = Common.Builder.forbid_builds builder in
        Common.Builder.disable_log_file builder
      in
      Common.init builder
    in
    (* CR-soon rgrinberg: remove pointless args *)
    Scheduler_setup.no_build_no_rpc ~config (fun () ->
      Server.dump ~selected_context ~format dir)
  ;;

  let command = Cmd.v info term
end

let doc = "Start a merlin configuration server."

let man =
  [ `S "DESCRIPTION"
  ; `P
      {|$(b,dune ocaml-merlin) starts a server that can be queried to get
      .merlin information. It is meant to be used by Merlin itself and does not
      provide a user-friendly output.|}
  ; `Blocks Common.help_secs
  ; Common.footer
  ]
;;

let start_session_info name = Cmd.info name ~doc ~man

let start_session_term =
  let+ builder = Common.Builder.term
  and+ selected_context = Selected_context.arg in
  let _common, config =
    let builder =
      let builder = Common.Builder.forbid_builds builder in
      Common.Builder.disable_log_file builder
    in
    Common.init builder
  in
  (* CR-soon rgrinberg: remove pointless args *)
  Scheduler_setup.no_build_no_rpc ~config (Server.start ~selected_context)
;;

let command = Cmd.v (start_session_info "ocaml-merlin") start_session_term

module Dump_dot_merlin = struct
  let doc = "Print Merlin configuration"

  let man =
    [ `S "DESCRIPTION"
    ; `P
        {|$(b,dune ocaml dump-dot-merlin) will attempt to read previously
        generated configuration in a source folder, merge them and print
        it to the standard output in Merlin configuration syntax. The
        output of this command should always be checked and adapted to
        the project needs afterward.|}
    ; Common.footer
    ]
  ;;

  let info = Cmd.info "dump-dot-merlin" ~doc ~man

  let term =
    let+ builder = Common.Builder.term
    and+ path =
      Arg.(
        value
        & pos 0 (some string) None
        & info
            []
            ~docv:"PATH"
            ~doc:
              (Some
                 "The path to the folder of which the configuration should be printed. \
                  Defaults to the current directory."))
    and+ selected_context = Selected_context.arg in
    let _common, config =
      let builder =
        let builder = Common.Builder.forbid_builds builder in
        Common.Builder.disable_log_file builder
      in
      Common.init builder
    in
    (* CR-soon rgrinberg: stop taking pointless args *)
    Scheduler_setup.no_build_no_rpc ~config (fun () ->
      match path with
      | Some s -> Server.dump_dot_merlin ~selected_context s
      | None -> Server.dump_dot_merlin ~selected_context ".")
  ;;

  let command = Cmd.v info term
end

let group =
  Cmdliner.Cmd.group
    (Cmd.info "merlin" ~doc:"Command group related to merlin")
    [ Dump_config.command; Cmd.v (start_session_info "start-session") start_session_term ]
;;
