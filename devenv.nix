{ pkgs, ... }:
{
  languages.clojure.enable = true;
  languages.opentofu.enable = true;
  packages = with pkgs; [
    babashka bun curl jq kubectl openssl
    openjdk21 netcat-openbsd uv
  ];
}
