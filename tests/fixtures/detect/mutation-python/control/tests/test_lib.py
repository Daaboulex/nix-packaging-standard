from lib import price


def test_price():
    assert price(10, 2, 1) == 21
    assert price(3, 5, 7) == 22
