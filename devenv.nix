{ pkgs
, lib
, config
, inputs
, ...
}:
let
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  packages = [
    pkgs.git
    pkgs.nixd
    pkgs.watchman
    pkgs.hut
    pkgs-unstable.opencode
    pkgs.ffmpeg
    pkgs.awscli2
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
    initialScript = ''
      CREATE ROLE sonnet WITH SUPERUSER LOGIN PASSWORD 'sonnet';
    '';
  };

  services.garage = {
    enable = true;
    buckets = [ "sonnet-dev" ];
    region = "us-east-1";
    afterStart = ''
      export AWS_ACCESS_KEY_ID=GKdevaccesskey001
      export AWS_SECRET_ACCESS_KEY=dev-secret-key-abc123
      export AWS_DEFAULT_REGION=us-east-1

      garage key import $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY
      garage bucket allow --key $AWS_ACCESS_KEY_ID --read --write sonnet-dev

      cat > /tmp/sonnet-dev-cors.json <<'EOF'
      {
        "CORSRules": [
          {
            "AllowedHeaders": ["*"],
            "AllowedMethods": ["GET", "PUT", "POST", "DELETE", "HEAD"],
            "AllowedOrigins": ["*"],
            "ExposeHeaders": ["ETag"],
            "MaxAgeSeconds": 3000
          }
        ]
      }
      EOF

      aws --endpoint-url http://127.0.0.1:3900 \
        s3api put-bucket-cors \
        --bucket sonnet-dev \
        --cors-configuration file:///tmp/sonnet-dev-cors.json
    '';
  };

  services.keycloak = {
    enable = true;
    realms.dev = {
      path = "./realms/dev.json";
      export = true;
      import = true;
    };
    settings = {
      hostname = "localhost";
      http-host = "127.0.0.1";
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
