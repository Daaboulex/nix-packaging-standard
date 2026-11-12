import lib


def test_add():
    assert lib.add(1, 2) == 3


def test_sub():
    assert lib.sub(3, 1) == 2
    assert lib.sub(1, 3) == 2
