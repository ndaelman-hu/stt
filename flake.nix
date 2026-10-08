{
  description = "whisper-hs: speech-to-text with whisper.cpp, llama.cpp and sherpa-onnx";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # nixpkgs builds whisper.cpp CPU-only by default; the Vulkan backend lets it use
      # an integrated or discrete GPU through Mesa (Intel ANV / AMD RADV) or vendor drivers.
      whisperCpp = pkgs.whisper-cpp.override { vulkanSupport = true; };
      # Vulkan drivers from the host can't be loaded by a Nix binary (its loader can't find
      # the host's bare "libvulkan_intel.so"), so point the loader at Mesa's Nix-built ICDs.
      # Mesa picks whichever driver matches the GPU present; whisper falls back to CPU otherwise.
      mesaIcds = "${pkgs.mesa}/share/vulkan/icd.d";
    in
    {
      # GHC and Cabal for the app; the three engines prebuilt from nixpkgs instead of setup.sh's local builds.
      # arecord comes from the host (Debian's alsa-utils), so it uses the host's PipeWire/ALSA setup.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          ghc cabal-install zlib pkg-config
          whisperCpp llama-cpp sherpa-onnx
        ];
        # Environment variables take precedence over .env (dotenv doesn't override), so these always win.
        env = {
          WHISPER_BINARY_PATH = "${whisperCpp}/bin/whisper-cli";
          LLM_BINARY_PATH = "${pkgs.llama-cpp}/bin/llama-cli";
          DIARIZE_BINARY_PATH = "${pkgs.sherpa-onnx}/bin/sherpa-onnx-offline-speaker-diarization";
          VK_ICD_FILENAMES = "${mesaIcds}/intel_icd.x86_64.json:${mesaIcds}/radeon_icd.x86_64.json";
        };
      };
    };
}
