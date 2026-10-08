{
  description = "whisper-hs: speech-to-text with whisper.cpp, llama.cpp and sherpa-onnx";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # GHC and Cabal for the app; the three engines prebuilt from nixpkgs instead of setup.sh's local builds.
      # arecord comes from the host (Debian's alsa-utils), so it uses the host's PipeWire/ALSA setup.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          ghc cabal-install zlib pkg-config
          whisper-cpp llama-cpp sherpa-onnx
        ];
        # Environment variables take precedence over .env (dotenv doesn't override), so these always win.
        env = {
          WHISPER_BINARY_PATH = "${pkgs.whisper-cpp}/bin/whisper-cli";
          LLM_BINARY_PATH = "${pkgs.llama-cpp}/bin/llama-cli";
          DIARIZE_BINARY_PATH = "${pkgs.sherpa-onnx}/bin/sherpa-onnx-offline-speaker-diarization";
        };
      };
    };
}
