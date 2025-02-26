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
      #pkgs-x86 = import nixpkgs { system = "i686-linux"; };
      lib = pkgs.lib;
      llvm = pkgs.llvmPackages_latest;
      # TODO: real version
      env86-version = "1";
      alpine-version = "3.18";
      alpine-patch-version = "6";
      alpine-kernel-version = "6.1.129";
      alpine-kernel-patch-version = "0";
    in {
      packages = rec {
        alpine-kernel = pkgs.stdenv.mkDerivation rec {
          pname = "alpine-linux-lts";
          version = "${alpine-kernel-version}-r${alpine-kernel-patch-version}";
          src = pkgs.fetchurl {
            url = "https://dl-cdn.alpinelinux.org/alpine/v${alpine-version}/main/x86/linux-lts-${version}.apk";
            hash = "sha256-iNN9TR+7BKtJBS8GJzhjncxHom0p1Vn8d5JRWJ4mB0w=";
          };

          unpackPhase = ''
            tar -xvf $src
          '';

          buildPhase = ''
            true
          '';

          installPhase = ''
            mkdir -p "$out"
            shopt -s extglob
            cp -r !(env-vars) "$out"/
          '';

          dontFixup = true;
        };
        alpine-initramfs = pkgs.stdenv.mkDerivation rec {
          pname = "alpine-initramfs";
          version = alpine-version;
          # mkinitfs needs a root filesystem to work from
          #src = pkgs.fetchurl {
          #  url = "https://dl-cdn.alpinelinux.org/alpine/v${alpine-version}/releases/x86/alpine-minirootfs-${alpine-version}.${alpine-patch-version}-x86.tar.gz";
          #  hash = "sha256-WayxARDRGvHwHtwYL7OK1Y8DzOFeqswTAEHmQdGP3Y0=";
          #};
          #unpackPhase = ''
          #  tar -xvf $src
          #'';
          src = pkgs.fetchurl {
            url = "https://dl-cdn.alpinelinux.org/alpine/v${alpine-version}/releases/x86/alpine-standard-${alpine-version}.${alpine-patch-version}-x86.iso";
            hash = "sha256-cgsWRrsNkwTqhhgTFLYeylR/U3l0eoivTHACdFojMCs=";
          };
          unpackPhase = ''
            mkdir -p .iso
            7z x -o.iso "$src"

            gzip -cd .iso/boot/initramfs-lts | cpio -idmv

            rm -rf .iso
          '';

          nativeBuildInputs = with pkgs;[
            self.packages.${system}.mkinitfs-hack
            p7zip
            cpio
            pax-utils
            kmod
          ];


          buildPhase = ''
            cp -r ${self.packages.${system}.alpine-kernel}/* .

            export SYSCONFDIR=${self.packages.${system}.mkinitfs}/etc/mkinitfs
            export DATADIR=${self.packages.${system}.mkinitfs}/usr/share/mkinitfs

            mkinitfs-hack \
              -F "ata base ide scsi virtio ext4 9p" \
              -b "$(pwd)" \
              ${alpine-kernel-version}-${alpine-kernel-patch-version}-lts
          '';


          installPhase = ''
            mkdir -p "$out"
            cp -r boot/initramfs-lts "$out"/
          '';

          dontFixup = true;

        };
        mkinitfs-hack = let
          script-src = builtins.readFile ./mkinitfs;
        in
          (pkgs.writeScriptBin "mkinitfs-hack" script-src).overrideAttrs(old: {
            buildCommand = "${old.buildCommand}\n patchShebangs $out";
          });
        mkinitfs = pkgs.stdenv.mkDerivation rec {
          pname = "mkinitfs";
          version = "3.11.1";
          src = pkgs.fetchFromGitHub {
            owner = "alpinelinux";
            repo = pname;
            rev = version;
            hash = "sha256-yxZFn8BjIkcd+2560/dvh37rfshKlfG0LgRH19QR++c=";
          };

          patchPhase = ''
            substituteInPlace Makefile \
              --replace "CFLAGS ?= -Wall -Werror -g" "CFLAGS ?= -Wall -g"

            # O_CREAT needs a file mode, no idea what this should be though
            # This similar issue https://github.com/pantheon-systems/fusedav/issues/204
            # suggests 0600
            substituteInPlace nlplug-findfs/nlplug-findfs.c \
              --replace "fd = open(outfile, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC);" \
                "fd = open(outfile, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);"
          '';

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs = with pkgs; [
            kmod
            util-linux
            cryptsetup
          ];

          makeFlags= [
            "DESTDIR=$(out)"
            "sbindir=/bin"
          ];
        };
        guest86-modules = (pkgs.buildGoModule {
          name = "env86-modules";
          version = env86-version;
          src = ./cmd/guest86;

          vendorHash = "sha256-e2Nq1Oaqccw2CYe7+P+SVEVBC4DkzRuS6RlxQ4fXZnE=";

        }).goModules;
        # VM Guest binary, must always be i386 and linked normally
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

          dontFixup = true;
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
            cp -r ${self.packages.${system}.alpine-kernel}/boot/vmlinuz-lts assets/vmlinuz.bin
            cp -r ${self.packages.${system}.alpine-initramfs}/initramfs-lts assets/initramfs.bin
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
          pax-utils
          go
          gnumake
        ];
      };
    });
}