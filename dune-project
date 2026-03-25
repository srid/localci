(lang dune 3.0)
(name localci)
(generate_opam_files true)

(package
 (name localci)
 (depends
  (ocaml (>= 4.14))
  cmdliner
  yojson))
