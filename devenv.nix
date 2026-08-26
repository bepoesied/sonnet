{ pkgs
, lib
, config
, inputs
, ...
}:
let
  garageNginxPort = 3900;
  garageS3UpstreamPort = 3904;
in
{
  packages = [
    pkgs.git
    pkgs.nixd
    pkgs.watchman
    pkgs.hut
    pkgs.ffmpeg
    pkgs.inotify-tools
    pkgs.tailwindcss_4
  ];

  languages.nix.enable = true;
  languages.elixir.enable = true;
  languages.javascript.enable = true;
  languages.javascript.directory = "./assets";
  languages.javascript.npm.enable = true;
  languages.javascript.npm.install.enable = true;

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
    port = 5432;
    initialScript = ''
      CREATE ROLE sonnet WITH SUPERUSER LOGIN PASSWORD 'sonnet';
    '';
  };

  services.garage = {
    enable = true;
    buckets = [ "sonnet-dev" ];
    region = "us-east-1";
    s3Address = "0.0.0.0:${toString garageS3UpstreamPort}";
    replicationFactor = 1;
    afterStart = ''
      garage key import GKdevaccesskey001 dev-secret-key-abc123 --yes
      garage bucket allow --key GKdevaccesskey001 --read --write sonnet-dev
    '';
  };

  services.nginx = {
    enable = true;
    httpConfig = ''
      server {
        listen 0.0.0.0:${toString garageNginxPort};
        server_name localhost;
        client_max_body_size 0;

        location / {
          if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET, PUT, POST, DELETE, HEAD, OPTIONS" always;
            add_header Access-Control-Allow-Headers "*" always;
            add_header Access-Control-Expose-Headers "ETag, x-amz-request-id, x-amz-id-2, x-amz-version-id, Content-Length, Content-Range, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 204;
          }

          add_header Access-Control-Allow-Origin "*" always;
          add_header Access-Control-Allow-Methods "GET, PUT, POST, DELETE, HEAD, OPTIONS" always;
          add_header Access-Control-Allow-Headers "*" always;
          add_header Access-Control-Expose-Headers "ETag, x-amz-request-id, x-amz-id-2, x-amz-version-id, Content-Length, Content-Range, Content-Type" always;

          proxy_http_version 1.1;
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_set_header Host $http_host;
          proxy_set_header Connection "";
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_pass http://localhost:${toString garageS3UpstreamPort};
        }
      }
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
      http-port = 38080;
      https-port = 34429;
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

  devcontainer.enable = true;

}
