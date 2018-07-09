open Import

type t =
  | Values of Value.t list
  | Project_root
  | First_dep
  | Deps
  | Targets
  | Named_local
  | Exe
  | Dep
  | Bin
  | Lib
  | Libexec
  | Lib_available
  | Version
  | Read
  | Read_strings
  | Read_lines
  | Path_no_dep
  | Ocaml_config

type with_info =
  | No_info    of t
  | Since      of t * Syntax.Version.t
  | Deleted_in of t * Syntax.Version.t * string option
  | Renamed_in of Syntax.Version.t * string

module Map = struct
  type t = with_info String.Map.t

  let values v                       = No_info (Values v)
  let renamed_in ~new_name ~version  = Renamed_in (version, new_name)
  let deleted_in ~version ?repl kind = Deleted_in (kind, version, repl)
  let since ~version v               = Since (v, version)

  let static =
    let macro x = No_info x in
    [ "targets", since ~version:(1, 0) Targets
    ; "deps", since ~version:(1, 0) Deps
    ; "project_root", since ~version:(1, 0) Project_root

    ; "<", deleted_in First_dep ~version:(1, 0)
             ~repl:"Use a named dependency instead:\
                    \n\
                    \n\  (deps (:x <dep>) ...)\
                    \n\   ... %{x} ..."
    ; "@", renamed_in ~version:(1, 0) ~new_name:"targets"
    ; "^", renamed_in ~version:(1, 0) ~new_name:"deps"
    ; "SCOPE_ROOT", renamed_in ~version:(1, 0) ~new_name:"project_root"

    ; "exe", macro Exe
    ; "bin", macro Bin
    ; "lib", macro Lib
    ; "libexec", macro Libexec
    ; "lib-available", macro Lib_available
    ; "version", macro Version
    ; "read", macro Read
    ; "read-lines", macro Read_lines
    ; "read-strings", macro Read_strings

    ; "dep", since ~version:(1, 0) Dep

    ; "path", renamed_in ~version:(1, 0) ~new_name:"dep"
    ; "findlib", renamed_in ~version:(1, 0) ~new_name:"lib"

    ; "path-no-dep", deleted_in ~version:(1, 0) Path_no_dep
    ; "ocaml-config", macro Ocaml_config
    ]
    |> String.Map.of_list_exn

  let create ~(context : Context.t) ~cxx_flags =
    let ocamlopt =
      match context.ocamlopt with
      | None -> Path.relative context.ocaml_bin "ocamlopt"
      | Some p -> p
    in
    let string s = values [Value.String s] in
    let path p = values [Value.Path p] in
    let make =
      match Bin.make with
      | None   -> string "make"
      | Some p -> path p
    in
    let cflags = context.ocamlc_cflags in
    let strings s = values (Value.L.strings s) in
    let lowercased =
      [ "cpp"            , strings (context.c_compiler :: cflags @ ["-E"])
      ; "cc"             , strings (context.c_compiler :: cflags)
      ; "cxx"            , strings (context.c_compiler :: cxx_flags)
      ; "ocaml"          , path context.ocaml
      ; "ocamlc"         , path context.ocamlc
      ; "ocamlopt"       , path ocamlopt
      ; "arch_sixtyfour" , string (string_of_bool context.arch_sixtyfour)
      ; "make"           , make
      ; "root"           , values [Value.Dir context.build_dir]
      ]
    in
    let uppercased =
      List.map lowercased ~f:(fun (k, _) ->
        (String.uppercase k, renamed_in ~new_name:k ~version:(1, 0)))
    in
    let other =
      [ "-verbose"       , values []
      ; "pa_cpp"         , strings (context.c_compiler :: cflags
                                    @ ["-undef"; "-traditional";
                                       "-x"; "c"; "-E"])
      ; "ocaml_bin"      , path context.ocaml_bin
      ; "ocaml_version"  , string context.version_string
      ; "ocaml_where"    , string (Path.to_string context.stdlib_dir)
      ; "null"           , string (Path.to_string Config.dev_null)
      ; "ext_obj"        , string context.ext_obj
      ; "ext_asm"        , string context.ext_asm
      ; "ext_lib"        , string context.ext_lib
      ; "ext_dll"        , string context.ext_dll
      ; "ext_exe"        , string context.ext_exe
      ; "profile"        , string context.profile
      ]
    in
    String.Map.superpose
      static
      (String.Map.of_list_exn
         (List.concat
            [ lowercased
            ; uppercased
            ; other
            ]))

  let superpose = String.Map.superpose

  let rec expand t ~syntax_version ~pform =
    let name = String_with_vars.Var.name pform in
    Option.bind (String.Map.find t name) ~f:(fun v ->
      let describe = String_with_vars.Var.describe in
      match v with
      | No_info v -> Some v
      | Since (v, min_version) ->
        if syntax_version >= min_version then
          Some v
        else
          Syntax.Error.since (String_with_vars.Var.loc pform)
            Stanza.syntax min_version
            ~what:(describe pform)
      | Renamed_in (in_version, new_name) -> begin
          if syntax_version >= in_version then
            Syntax.Error.renamed_in (String_with_vars.Var.loc pform)
              Stanza.syntax syntax_version
              ~what:(describe pform)
              ~to_:(describe
                      (String_with_vars.Var.with_name pform ~name:new_name))
          else
            expand t ~syntax_version:in_version
              ~pform:(String_with_vars.Var.with_name pform ~name:new_name)
        end
      | Deleted_in (v, in_version, repl) ->
        if syntax_version < in_version then
          Some v
        else
          Syntax.Error.deleted_in (String_with_vars.Var.loc pform)
            Stanza.syntax syntax_version ~what:(describe pform) ?repl)

  let empty = String.Map.empty

  let singleton k v = String.Map.singleton k (No_info v)

  let of_list_exn pforms =
    List.map ~f:(fun (k, x) -> (k, No_info x)) pforms
    |> String.Map.of_list_exn

  let of_bindings =
    Jbuild.Bindings.fold ~f:(fun x acc ->
      match x with
      | Unnamed _ -> acc
      | Named (s, _) -> String.Map.add acc s (No_info Named_local)
    ) ~init:empty

  let input_file path =
    let value = Values (Value.L.paths [path]) in
    [ "input-file", since ~version:(1, 0) value
    ; "<", renamed_in ~new_name:"input-file" ~version:(1, 0)
    ]
    |> String.Map.of_list_exn
end
