{
  description = ''A lightweight, self-contained, RESTful, searchable, multi-format NoSQL document store'';

  inputs.flakeNimbleLib.owner = "riinr";
  inputs.flakeNimbleLib.ref   = "master";
  inputs.flakeNimbleLib.repo  = "nim-flakes-lib";
  inputs.flakeNimbleLib.type  = "github";
  inputs.flakeNimbleLib.inputs.nixpkgs.follows = "nixpkgs";
  
  inputs.src-litestore-v1_0_4.flake = false;
  inputs.src-litestore-v1_0_4.owner = "h3rald";
  inputs.src-litestore-v1_0_4.ref   = "refs/tags/v1.0.4";
  inputs.src-litestore-v1_0_4.repo  = "litestore";
  inputs.src-litestore-v1_0_4.type  = "github";
  
  inputs."nimrod".owner = "nim-nix-pkgs";
  inputs."nimrod".ref   = "master";
  inputs."nimrod".repo  = "nimrod";
  inputs."nimrod".type  = "github";
  inputs."nimrod".inputs.nixpkgs.follows = "nixpkgs";
  inputs."nimrod".inputs.flakeNimbleLib.follows = "flakeNimbleLib";
  
  outputs = { self, nixpkgs, flakeNimbleLib, ...}@deps:
  let 
    lib  = flakeNimbleLib.lib;
    args = ["self" "nixpkgs" "flakeNimbleLib" "src-litestore-v1_0_4"];
  in lib.mkRefOutput {
    inherit self nixpkgs ;
    src  = deps."src-litestore-v1_0_4";
    deps = builtins.removeAttrs deps args;
    meta = builtins.fromJSON (builtins.readFile ./meta.json);
  };
}