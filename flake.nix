{
  description = "Logos monero-nix — one source-built Monero tree, two C-ABI shared libraries (wallet2 + daemon).";

  inputs = {
    # logos-nix is the ROOT of the family's nixpkgs pin (the workspace itself does
    # `nixpkgs.follows = "logos-nix/nixpkgs"`), and it owns the mingw cross package set.
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-nix, ... }:
    let
      lib = nixpkgs.lib;

      nativeSystems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      targets = nativeSystems ++ [ "x86_64-windows" ];

      # x86_64-windows is a pseudo-system: a cross derivation's `system` is its BUILD
      # platform, so this evaluates anywhere and realises on Linux. Same shape as
      # logos-monero-wallet-core-module's flake.
      pkgsFor = system:
        if system == "x86_64-windows"
        then logos-nix.lib.mkWindowsPkgs { buildSystem = "x86_64-linux"; }
        else import nixpkgs { inherit system; };

      forAllTargets = f: lib.genAttrs targets (system: f (pkgsFor system));
    in
    {
      packages = forAllTargets (pkgs:
        let moneroSrc = import ./nix/monero-src.nix { inherit pkgs; };
        in {
          inherit moneroSrc;
          monero-src = moneroSrc;
          monerod-c = import ./nix/monerod-c.nix {
            inherit pkgs moneroSrc;
            shimSrc = ./shim;
          };
        });
    };
}
