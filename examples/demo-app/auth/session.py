"""Session cookies for the login flow."""

import secrets

# Renamed from "session" to "sid" to match the gateway's cookie policy.
COOKIE_NAME = "sid"


def create_session(user_id: str) -> dict:
    """Return the cookies to set after a successful login."""
    token = f"{user_id}:{secrets.token_hex(8)}"
    return {COOKIE_NAME: token}
