def price(amount, rate, fee):
    total = amount * rate
    total = total + fee
    return total
