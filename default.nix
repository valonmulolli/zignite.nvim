{ pkgs ? import <nixpkgs> { } }:

let
  pname = "zignite-nvim";
  version = "unstable";
in
pkgs.rustPlatform.buildRustPackage {
  inherit pname version;
  src = ./.;
  cargoRoot = "rust";
  cargoLock.lockFile = ./rust/Cargo.lock;

  doCheck = false;

  buildPhase = ''
    runHook preBuild
    ${pkgs.cargo}/bin/cargo build --manifest-path rust/Cargo.toml --release --locked
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    plugin_dir="$out/share/vim-plugins/${pname}"

    mkdir -p "$plugin_dir"
    cp -r lua plugin doc README.md LICENSE "$plugin_dir/"
    mkdir -p "$plugin_dir/rust/target/release"
    cp rust/target/release/zignite "$plugin_dir/rust/target/release/zignite"
    chmod 0755 "$plugin_dir/rust/target/release/zignite"

    test -x "$plugin_dir/rust/target/release/zignite"
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Asynchronous Neovim code runner with a Rust backend";
    homepage = "https://github.com/valonmulolli/zignite.nvim";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}
