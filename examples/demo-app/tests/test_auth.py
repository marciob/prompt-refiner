from auth.session import create_session


def test_login_sets_cookie():
    cookies = create_session("u1")
    assert cookies["session"].startswith("u1:")
