{
	description = "cj5 JSON5 parser - Zig bindings for the C library";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs systems;
		in {
			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							git
						];
					};
				});

			# `nix flake check` / Garnix run this: it actually executes `zig build test`.
			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					# Zig bundles musl, so targeting *-linux-musl needs no system libc
					# and builds + runs fully self-contained inside the Nix sandbox.
					# Static musl binaries execute fine on the glibc build host.
					# Darwin uses the native toolchain.
					zigTarget =
						if system == "x86_64-linux" then "x86_64-linux-musl"
						else if system == "aarch64-linux" then "aarch64-linux-musl"
						else "native";
				in {
					tests = pkgs.stdenvNoCC.mkDerivation {
						name = "cj5-tests";
						src = ./.;
						nativeBuildInputs = [ pkgs.zig ];
						dontConfigure = true;
						buildPhase = ''
							# Zig needs writable cache dirs; the sandbox $HOME is read-only.
							export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
							export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
							# Nix's stdenv flags can break Zig's own linker invocation.
							unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
							zig build test -Dtarget=${zigTarget}
						'';
						installPhase = "touch $out";
					};
				});
		};
}
