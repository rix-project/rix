{
  lib,
  zig,
  stdenv,
  self,
}:

stdenv.mkDerivation rec {
  name = "zix-${version}";
  version = "0.1.0";

  src = self;

  nativeBuildInputs = [
    zig
    zig.hook
  ];

  meta = {
    description = "A simple package manager for NixOS";
    homepage = "https://github.com/zix-os/zix";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.all;
  };
}
