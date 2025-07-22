{
  lib,
  stdenv,
  clipnotify,
  wl-clipboard,
  xclip,
  clipsync-unwrapped ? null,
}:
stdenv.mkDerivation {
  inherit (clipsync-unwrapped) pname version;

  buildInputs = [
    clipnotify
    wl-clipboard
    xclip
  ];

  doCheck = false;

  meta = {
    inherit (clipsync-unwrapped)
      homepage
      description
      license
      mainProgram
      ;
    maintainers = [ lib.maintainers.definfo ];
  };
}
