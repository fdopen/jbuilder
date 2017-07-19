open Import
open Build.O
open! No_io

module SC = Super_context

type t =
  { requires   : (unit, Lib.t list) Build.t
  ; flags      : string list
  ; preprocess : Jbuild.Preprocess.t
  ; libname    : string option
  }

let ppx_flags sctx ~scope ~dir ~src_dir { preprocess; libname; _ } =
  match preprocess with
  | Pps { pps; flags } ->
    let exe = SC.PP.get_ppx_driver sctx pps ~scope ~dir ~dep_kind:Optional in
    let command =
      List.map (Path.reach exe ~from:src_dir
                :: "--as-ppx"
                :: SC.PP.cookie_library_name libname
                @ flags)
        ~f:quote_for_shell
      |> String.concat ~sep:" "
    in
    [sprintf "FLG -ppx \"%s\"" command]
  | _ -> []

let dot_merlin sctx ~scope ~dir ({ requires; flags; _ } as t) =
  match Path.extract_build_context dir with
  | Some (_, remaindir) ->
    let path = Path.relative remaindir ".merlin" in
    SC.add_rule sctx
      (Build.path path
       >>>
       Build.update_file (Path.relative dir ".merlin-exists") "");
    SC.add_rule sctx (
      requires
      >>^ (fun libs ->
        let ppx_flags = ppx_flags sctx ~scope ~dir ~src_dir:remaindir t in
        let internals, externals =
          List.fold_left libs ~init:([], []) ~f:(fun (internals, externals) ->
            function
            | Lib.Internal (path, _) ->
              let spath =
                Path.drop_build_context path
                |> Path.reach ~from:remaindir
              in
              let bpath = Path.reach path ~from:remaindir in
              ("S " ^ spath) :: ("B " ^ bpath) :: internals, externals
            | Lib.External pkg ->
              internals, ("PKG " ^ pkg.name) :: externals
          )
        in
        let flags =
          match flags with
          | [] -> []
          | _  -> ["FLG " ^ String.concat flags ~sep:" "]
        in
        let dot_merlin =
          List.concat
            [ [ "B " ^ (Path.reach dir ~from:remaindir) ]
            ; internals
            ; externals
            ; flags
            ; ppx_flags
            ]
        in
        dot_merlin
        |> String_set.of_list
        |> String_set.elements
        |> List.map ~f:(Printf.sprintf "%s\n")
        |> String.concat ~sep:"")
      >>>
      Build.update_file_dyn path
    )
  | _ ->
    ()

let merge_two a b =
  { requires =
      (Build.fanout a.requires b.requires
       >>^ fun (x, y) ->
       Lib.remove_dups_preserve_order (x @ y))
  ; flags = a.flags @ b.flags
  ; preprocess =
      if a.preprocess = b.preprocess then
        a.preprocess
      else
        No_preprocessing
  ; libname =
      match a.libname with
      | Some _ as x -> x
      | None -> b.libname
  }

let add_rules sctx ~scope ~dir ts =
  if (SC.context sctx).merlin then
    match ts with
    | [] -> ()
    | t :: ts -> dot_merlin sctx ~scope ~dir (List.fold_left ts ~init:t ~f:merge_two)
