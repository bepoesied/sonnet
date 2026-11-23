defmodule SonnetWeb.AuthHTML do
  use SonnetWeb, :html

  embed_templates "auth_html/*"

  def error_description(:invalid_redirect_uri),
    do: "The requested mobile redirect URI is not allowed."

  def error_description(:invalid_code_challenge_method),
    do: "PKCE with S256 is required for mobile sign-in."

  def error_description(:invalid_code_challenge),
    do: "The PKCE code challenge is missing or invalid."

  def error_description(:invalid_state),
    do: "The mobile authentication state parameter is missing or invalid."

  def error_description(:invalid_flow_state),
    do: "Your sign-in session could not be verified. Please try signing in again."

  def error_description(:user_provisioning_failed),
    do: "Your account could not be created or updated from the identity provider."

  def error_description(_reason),
    do: "Authentication could not be completed. Please try signing in again."
end
