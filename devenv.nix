{ pkgs, lib, config, inputs, ... }:

{
  packages = [
    pkgs.git
    pkgs.nixd
    pkgs.watchman
    pkgs.hut
  ];

  languages.nix.enable = true;
  languages.elixir.enable = true;
  languages.javascript.enable = true;

  git-hooks.hooks = {
    check-shebang-scripts-are-executable.enable = true;
    check-symlinks.enable = true;
    check-yaml.enable = true;
    check-merge-conflicts.enable = true;
    check-json.enable = true;
    check-executables-have-shebangs.enable = true;
    check-added-large-files.enable = true;
    check-case-conflicts.enable = true;
    markdownlint.enable = true;
    nixpkgs-fmt.enable = true;
    prettier.enable = true;
    trufflehog.enable = true;
    mix-format.enable = true;
    mixed-line-endings.enable = true;
  };

  env = {
    SONNET_OIDCC_CLIENT_ID = config.secretspec.secrets.SONNET_OIDCC_CLIENT_ID or "";
    SONNET_OIDCC_CLIENT_SECRET = config.secretspec.secrets.SONNET_OIDCC_CLIENT_SECRET or "";
    SONNET_OIDCC_ISSUER = config.secretspec.secrets.SONNET_OIDCC_ISSUER or "";
    SONNET_S3_ACCESS_KEY_ID = config.secretspec.secrets.SONNET_S3_ACCESS_KEY_ID or "";
    SONNET_S3_ACCESS_KEY_SECRET = config.secretspec.secrets.SONNET_S3_ACCESS_KEY_SECRET or "";
    SONNET_S3_HOST = config.secretspec.secrets.SONNET_S3_HOST or "";
  };
}
