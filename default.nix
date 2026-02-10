{
  craneLib,
  self,
}:

craneLib.buildPackage {
  pname = "rix";
  version = "0.1.0";
  src = craneLib.cleanCargoSource self;

  nativeBuildInputs = [
  ];

  buildInputs = [

  ];
}
