open Import
open Dune_rpc

module Status = struct
  module Menu = struct
    type t =
      | Uninitialized
      | Menu of (Method.Name.t * int) list

    let sexp =
      let open Conv in
      let menu = constr "menu" (list (pair Method.Name.sexp int)) (fun m -> Menu m) in
      let uninitialized = constr "stage1" unit (fun () -> Uninitialized) in
      let variants = [ econstr menu; econstr uninitialized ] in
      sum variants (function
        | Uninitialized -> case () uninitialized
        | Menu m -> case m menu)
    ;;
  end

  type t = { clients : (Id.t * Menu.t) list }

  let sexp =
    let open Conv in
    let to_ clients = { clients } in
    let from { clients } = clients in
    iso (list (pair Id.sexp Menu.sexp)) to_ from
  ;;

  let v1 = Decl.Request.make_current_gen ~req:Conv.unit ~resp:sexp ~version:1

  let decl =
    Decl.Request.make ~method_:(Method.Name.of_string "status") ~generations:[ v1 ]
  ;;
end

module Build = struct
  let v1 =
    Decl.Request.make_current_gen
      ~req:(Conv.list Conv.string)
      ~resp:Dune_rpc.Build_outcome_with_diagnostics.sexp_v1
      ~version:1
  ;;

  let v2 =
    Decl.Request.make_current_gen
      ~req:(Conv.list Conv.string)
      ~resp:Dune_rpc.Build_outcome_with_diagnostics.sexp_v2
      ~version:2
  ;;

  let decl =
    Decl.Request.make ~method_:(Method.Name.of_string "build") ~generations:[ v1; v2 ]
  ;;
end

module Resolve_program = struct
  module Request = struct
    type t =
      { context : string
      ; source_dir : string
      ; program : string
      }

    let sexp =
      let open Conv in
      let context = field "context" (required string) in
      let source_dir = field "source_dir" (required string) in
      let program = field "program" (required string) in
      let to_ (context, source_dir, program) = { context; source_dir; program } in
      let from { context; source_dir; program } = context, source_dir, program in
      iso (record (three context source_dir program)) to_ from
    ;;
  end

  module Response = struct
    module Resolution = struct
      module Build_path = struct
        type t =
          { target : string
          ; path : string
          }

        let sexp =
          let open Conv in
          let target = field "target" (required string) in
          let path = field "path" (required string) in
          let to_ (target, path) = { target; path } in
          let from { target; path } = target, path in
          iso (record (both target path)) to_ from
        ;;
      end

      type t =
        | In_build_dir of Build_path.t
        | External of string

      let sexp =
        let open Conv in
        let in_build_dir =
          constr "in-build-dir" Build_path.sexp (fun path -> In_build_dir path)
        in
        let external_ = constr "external" string (fun path -> External path) in
        let variants = [ econstr in_build_dir; econstr external_ ] in
        sum variants (function
          | In_build_dir path -> case path in_build_dir
          | External path -> case path external_)
      ;;
    end

    type t =
      | Found of Resolution.t
      | Not_found

    let sexp =
      let open Conv in
      let found = constr "found" Resolution.sexp (fun resolved -> Found resolved) in
      let not_found = constr "not-found" unit (fun () -> Not_found) in
      let variants = [ econstr found; econstr not_found ] in
      sum variants (function
        | Found resolved -> case resolved found
        | Not_found -> case () not_found)
    ;;
  end

  let v1 = Decl.Request.make_current_gen ~req:Request.sexp ~resp:Response.sexp ~version:1

  let decl =
    Decl.Request.make
      ~method_:(Method.Name.of_string "resolve-program")
      ~generations:[ v1 ]
  ;;
end

let build = Build.decl
let resolve_program = Resolve_program.decl
let status = Status.decl
