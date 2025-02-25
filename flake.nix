{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, poetry2nix, ... }:
    flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      llvm = pkgs.llvmPackages_latest;
      # TODO: real version
      env86-version = "1";
    in {
      packages = rec {
        guest86-modules = (pkgs.buildGoModule {
          name = "env86-modules";
          version = env86-version;
          src = ./cmd/guest86;

          vendorHash = "sha256-e2Nq1Oaqccw2CYe7+P+SVEVBC4DkzRuS6RlxQ4fXZnE=";

        }).goModules;
        guest86 = pkgs.stdenv.mkDerivation rec {
          pname = "guest86";
          version = env86-version;
          src = ./.;

          nativeBuildInputs = with pkgs; [
            go
          ];

          buildPhase = ''
            export GOCACHE=$TMPDIR/go-cache
            export GOPATH="$TMPDIR/go"
            export GOOS=linux
            export GOARCH=386


            cd cmd/guest86
            mkdir vendor
            cp -r ${self.packages.${system}.guest86-modules}/* vendor/
            go build -o guest86 .
          '';

          installPhase = ''
            mkdir -p "$out/bin/"
            cp guest86 "$out/bin/"
          '';
        };
        v86-bin = pkgs.stdenv.mkDerivation rec {
          pname = "v86-bin";
          version = "ec3ecde";
          srcs = [
            (pkgs.fetchFromGitHub {
              owner = "copy";
              repo = "v86";
              rev = version;
              hash = "sha256-hsR51YFlwp110P3sDLVCSHM6kMLwnk1WqvDfKTTnsso=";
            })
            # HACK: Makefile fetches this with wget, prefetch here
            (pkgs.fetchurl {
              name = "compiler.jar";
              url = "https://repo1.maven.org/maven2/com/google/javascript/closure-compiler/v20210601/closure-compiler-v20210601.jar";
              hash = "sha256-ZPFhxlo9ukLJpPWnnbM1rA51f8ukhs15KCBaxMJY7wg=";
            })
          ];

          sourceRoot = ".";

          nativeBuildInputs = with pkgs; [
            nodejs
            llvm.clang-unwrapped
            cargo
            lld
            python3
            jre
          ];

          # Needed so clang-unwrapped can find the proper headers
          CPATH = builtins.concatStringsSep ":" [
            (lib.makeSearchPathOutput "dev" "include" [llvm.libcxx])
            (lib.makeSearchPath "resource-root/include" [llvm.clang])
          ];

          unpackPhase = ''
            for src in ''${srcs}; do
              if [[ -d "$src" ]]; then
                echo "Copying $src to build path"
                cp -r "$src/"* .
              elif [[ -f "$src" ]] && [[ "$src" == *compiler.jar ]]; then
                echo "Copying $src to compiler path"
                mkdir -p closure-compiler
                cp "$src" closure-compiler/compiler.jar
              fi
            done
            chmod -R 777 *
          '';

          patchPhase = ''
            # Build relies on many scripts with /usr/bin/env
            patchShebangs --build *

            # Why does cargo rustc build files to the wrong path?
            # This doesn't seem to happen when building with a devshell
            substituteInPlace Makefile \
              --replace "cp build/wasm32-unknown-unknown/" "cp target/wasm32-unknown-unknown/" \
          '';

          buildPhase = ''
            runHook preBuild

            make build/libv86.js
            make build/v86.wasm

            runHook postbuild
          '';

          installPhase = ''
            mkdir -p "$out"
            cp build/libv86.js "$out"/
            cp build/v86.wasm "$out"/
            cp bios/seabios.bin "$out"/
            cp bios/vgabios.bin "$out"/
          '';
        };
        env86-modules = (pkgs.buildGoModule {
          name = "env86-modules";
          version = env86-version;
          src = ./.;

          vendorHash = "sha256-gT+acETGvZnER4m+ZxPiQR+MBhx1rTtQSvCOnCITOlI=";
        }).goModules;

        env86 = pkgs.buildGoModule {
          name ="env86";

          # TODO: Real version
          version = env86-version;
          src = ./.;

          buildInputs = with pkgs; [
            gtk3
            webkitgtk_4_1
            libayatana-appindicator
          ];

          # Needed to vendor in guest86
          allowGoReference = true;

          patchPhase = ''
            # HACK: this package uses purego to link libraries at runtime,
            # which will fail since we have no global libs, patch the library
            # paths to point to nix store.
            # Note: we have to copy these files from another (unmodified) package
            # since nix disallows store references inside a fixed-output derivation
            mkdir vendor
            cp -r ${self.packages.${system}.env86-modules}/* vendor/
            chmod -R 777 vendor
            sed -i 's|"libgtk-3.so"|"${pkgs.gtk3}/lib/libgtk-3.so"|' vendor/tractor.dev/toolkit-go/desktop/linux/linux.go
            sed -i 's|"libwebkit2gtk-4.1.so"|"${pkgs.webkitgtk_4_1}/lib/libwebkit2gtk-4.1.so"|' vendor/tractor.dev/toolkit-go/desktop/linux/linux.go
            sed -i 's|"libjavascriptcoregtk-4.1.so"|"${pkgs.webkitgtk_4_1}/lib/libjavascriptcoregtk-4.1.so"|' vendor/tractor.dev/toolkit-go/desktop/linux/linux.go
            sed -i 's|"libayatana-appindicator3.so.1"|"${pkgs.libayatana-appindicator}/lib/libayatana-appindicator3.so.1"|' vendor/tractor.dev/toolkit-go/desktop/linux/linux.go

            # HACK: Copy in guest binaries from outside packages
            cp -r ${self.packages.${system}.v86-bin}/* assets/
            cp -r ${self.packages.${system}.guest86}/bin/guest86 assets/
          '';
          vendorHash = null;

          # guest86 must be built externally
          excludedPackages = [
            "cmd/guest86"
          ];
        };

        default = env86;

      };
      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          go
          gnumake
        ];
      };
    });
}