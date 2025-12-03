{ pkgs
, lib
, config
, inputs
, ...
}:

{
  packages = [
    pkgs.git
    pkgs.nixd
    pkgs.watchman
    pkgs.hut

    pkgs.ffmpeg
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
    SONNET_S3_BUCKET = config.secretspec.secrets.SONNET_S3_BUCKET or "";
    SONNET_S3_PREFIX = config.secretspec.secrets.SONNET_S3_PREFIX or "";
  };

  services.postgres = {
    enable = true;
    listen_addresses = "localhost";
    initialDatabases = [
      {
        name = "sonnet_dev";
        user = "sonnet";
        pass = "sonnet";
      }
    ];
  };

  enterShell = ''
    # Install Hex and rebar if not already installed
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
  '';

  enterTest = ''
    # Ensure dependencies are fetched before running tests
    if [ -f mix.exs ]; then
      echo "Fetching dependencies for test environment..."
      mix deps.get
    fi
  '';
}
