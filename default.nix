{ pkgs ? import <nixpkgs> { } }:

let
  pname = "zignite-nvim";
  version = "unstable";
in
pkgs.vimUtils.buildVimPlugin {
  inherit pname version;
  src = ./.;
  doCheck = false;

  nativeBuildInputs = [ pkgs.zig ];

  postInstall = ''
    plugin_dir="$out/share/vim-plugins/${pname}"

    test -d "$plugin_dir/zig"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"

    (
      cd "$plugin_dir/zig"
      ${pkgs.zig}/bin/zig build -Doptimize=ReleaseFast
    )

    test -x "$plugin_dir/zig/zig-out/bin/zignite"
  '';

  meta = with pkgs.lib; {
    description = "Asynchronous Neovim code runner with a Zig backend";
    homepage = "https://github.com/valonmulolli/zignite.nvim";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}
