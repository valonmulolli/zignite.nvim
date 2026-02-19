{
  description = "zignite.nvim - asynchronous Neovim code runner with Zig backend";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        plugin = import ./default.nix { inherit pkgs; };
      in
      {
        packages.default = plugin;
        packages.zignite-nvim = plugin;

        checks = {
          package = plugin;
          lua-tests = pkgs.stdenvNoCC.mkDerivation {
            name = "zignite-lua-tests";
            src = ./.;
            nativeBuildInputs = [ pkgs.lua5_4 ];
            dontConfigure = true;
            dontBuild = true;
            doCheck = true;
            checkPhase = ''
              lua test/runner.lua
            '';
            installPhase = ''
              mkdir -p $out
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            lua5_4
            zig
            stylua
            nil
          ];
        };
      });
}
