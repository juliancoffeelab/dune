open Import
open Dune_rpc

(** Internal RPC requests *)

module Status : sig
  module Menu : sig
    type t =
      | Uninitialized
      | Menu of (Method.Name.t * int) list

    val sexp : (t, Conv.values) Conv.t
  end

  type t = { clients : (Id.t * Menu.t) list }

  val sexp : (t, Conv.values) Conv.t
end

module Resolve_program : sig
  module Request : sig
    type t =
      { context : string
      ; source_dir : string
      ; program : string
      }

    val sexp : (t, Conv.values) Conv.t
  end

  module Response : sig
    module Resolution : sig
      module Build_path : sig
        type t =
          { target : string
          ; path : string
          }

        val sexp : (t, Conv.values) Conv.t
      end

      type t =
        | In_build_dir of Build_path.t
        | External of string

      val sexp : (t, Conv.values) Conv.t
    end

    type t =
      | Found of Resolution.t
      | Not_found

    val sexp : (t, Conv.values) Conv.t
  end
end

val build : (string list, Build_outcome_with_diagnostics.t) Decl.Request.t

val resolve_program
  : (Resolve_program.Request.t, Resolve_program.Response.t) Decl.Request.t

val status : (unit, Status.t) Decl.Request.t
