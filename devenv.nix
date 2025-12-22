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

  services.minio = {
    enable = true;
    accessKey = "minioadmin";
    buckets = [ "sonnet-dev" ];
    region = "us-east-1";
    secretKey = "minioadmin";
    listenAddress = "0.0.0.0:9000";
  };

  services.keycloak = {
    enable = true;
    realms.dev = {
      path = "./realms/dev.json";
      export = true;
      import = true;
    };
    settings = {
      hostname = "viper.lan.kmr.internal";
      http-host = "0.0.0.0";
      http-port = 8080;
      https-port = 34429;
      http-management-port = lib.mkForce 8081;
    };
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
