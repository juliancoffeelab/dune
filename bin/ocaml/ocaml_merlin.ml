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
  let get_merlin_files_paths_in_dir dir =
    let merlin_path =
      Path.Build.relative dir Dune_rules.Merlin_ident.merlin_folder_name
    in
    Path.build merlin_path
    |> Path.readdir_unsorted
    |> Result.value ~default:[]
    |> List.sort ~compare:String.compare
    |> List.map ~f:(fun f -> Path.Build.relative merlin_path f |> Path.build)
  ;;

  let get_pkg_inner_merlin_files_paths dir =
    match Path.Build.extract_build_context dir with
    | None -> []
    | Some (context, source_dir) ->
      (match Path.Source.explode source_dir with
       | pkg_context :: ".pkg" :: pkg_digest :: "source" :: components ->
         let context = Context_name.of_string context in
         let pkg_source_root =
           Path.Build.L.relative
             (Context_name.build_dir context)
             [ pkg_context; ".pkg"; pkg_digest; "source" ]
         in
         let inner_build_dir =
           Path.Build.relative pkg_source_root "_build/default"
           |> fun root -> Path.Build.L.relative root components
         in
         get_merlin_files_paths_in_dir inner_build_dir
       | _ -> [])
  ;;

  let get_merlin_files_paths dir =
    List.concat
      [ get_merlin_files_paths_in_dir dir; get_pkg_inner_merlin_files_paths dir ]
  ;;

  module Merlin = Dune_rules.Merlin

  let no_config_found file =
    Path.Build.drop_build_context_exn file
    |> Path.Source.to_string_maybe_quoted
    |> Printf.sprintf "No config found for file %s. Try calling 'dune build'."
    |> Merlin_conf.make_error
  ;;

  let synthetic_pkg_merlin_conf file =
    let make_directive tag value = Sexp.List [ Sexp.Atom tag; value ] in
    let make_directive_of_path tag path =
      make_directive tag (Sexp.Atom (Path.to_absolute_filename path))
    in
    let unit_name_of_file file =
      let base =
        Path.Build.basename file |> Filename.remove_extension |> String.capitalize_ascii
      in
      Sexp.Atom base
    in
    let first_installed_lib_dir target_lib_root =
      match Path.readdir_unsorted target_lib_root with
      | Error _ -> None
      | Ok entries ->
        List.find_map entries ~f:(fun entry ->
          let path = Path.relative target_lib_root entry in
          match Path.stat path with
          | Ok { st_kind = S_DIR; _ } -> Some path
          | Ok _ | Error _ -> None)
    in
    match Path.Build.extract_build_context file with
    | None -> None
    | Some (context, source_path) ->
      (match Path.Source.explode source_path with
       | pkg_context :: ".pkg" :: pkg_digest :: "source" :: _ ->
         let context = Context_name.of_string context in
         let pkg_root =
           Path.Build.L.relative
             (Context_name.build_dir context)
             [ pkg_context; ".pkg"; pkg_digest ]
         in
         let source_root = Path.build (Path.Build.relative pkg_root "source") in
         let target_lib_root = Path.build (Path.Build.relative pkg_root "target/lib") in
         (match first_installed_lib_dir target_lib_root with
          | None -> None
          | Some obj_dir ->
            Some
              Sexp.(
                List
                  [ make_directive_of_path "B" obj_dir
                  ; make_directive_of_path "S" source_root
                  ; make_directive_of_path "SOURCE_ROOT" Path.root
                  ; List [ Atom "EXCLUDE_QUERY_DIR" ]
                  ; make_directive "UNIT_NAME" (unit_name_of_file file)
                  ]))
       | _ -> None)
  ;;

  let rec find_closest_config_for path ~file =
    match
      get_merlin_files_paths path
      |> List.find_map ~f:(fun file_path ->
        match Merlin.Processed.load_file file_path with
        | Error msg -> Some (Error (Merlin_conf.make_error msg))
        | Ok config ->
          (match Merlin.Processed.get config ~file with
           | Some config -> Some (Ok config)
           | None -> None))
    with
    | Some x -> Some x
    | None ->
      (match Path.Build.parent path with
       | None -> None
       | Some dir -> find_closest_config_for dir ~file)
  ;;

  let load_merlin_file file =
    match find_closest_config_for (Path.Build.parent_exn file) ~file with
    | Some (Error error) -> error
    | Some (Ok config) -> config
    | None ->
      (match synthetic_pkg_merlin_conf file with
       | Some conf -> conf
       | None -> no_config_found file)
  ;;

  let load_merlin_file_with_context ~target:_ ~context =
    match find_closest_config_for (Path.Build.parent_exn context) ~file:context with
    | Some (Error error) -> error
    | Some (Ok config) -> config
    | None -> no_config_found context
  ;;

  let to_workspace_path file_path =
    let error msg = Error msg in
    let abs_file_path = Path.of_filename_relative_to_initial_cwd file_path in
    match make_relative_to_root abs_file_path with
    | Some path ->
      (try Ok (Path.of_string path) with
       | User_error.E mess -> User_message.to_string mess |> error)
    | None ->
      Printf.sprintf
        "Path %s is not in dune workspace (%s)."
        (String.maybe_quoted file_path)
        (String.maybe_quoted @@ Path.(to_absolute_filename Path.root))
      |> error
  ;;

  let to_local ~selected_context file =
    match to_workspace_path file with
    | Error s -> Fiber.return (Error s)
    | Ok file ->
      if Path.is_in_build_dir file
      then Fiber.return (Ok (Path.as_in_build_dir_exn file))
      else (
        let file = Path.drop_optional_build_context file |> Path.local_part in
        match Dune_engine.Context_name.is_default selected_context with
        | false ->
          Fiber.return
            (Ok (Path.Build.append_local (Context_name.build_dir selected_context) file))
        | true ->
          let+ workspace = Memo.run (Workspace.workspace ()) in
          (match workspace.merlin_context with
           | None -> Error "no merlin context configured"
           | Some context ->
             Ok (Path.Build.append_local (Context_name.build_dir context) file)))
  ;;

  let print_merlin_conf ~selected_context ~path ~context =
    let+ config =
      to_local ~selected_context path
      >>= function
      | Ok file -> Fiber.return (load_merlin_file file)
      | Error error ->
        (match context with
         | None -> Fiber.return (Merlin_conf.make_error error)
         | Some context ->
           to_local ~selected_context context
           >>| (function
            | Error _ -> Merlin_conf.make_error error
            | Ok context -> load_merlin_file_with_context ~target:path ~context))
    in
    Merlin_conf.to_stdout config
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
