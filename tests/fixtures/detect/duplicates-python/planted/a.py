def alpha(values, limit):
    total = 0
    for item in values:
        if item > limit:
            total += item * 3
        elif item < -limit:
            total -= item // 3
        else:
            total ^= item
        if total > 1000:
            total = 1000
        if total < -1000:
            total = -1000
    for item in reversed(values):
        if item == limit:
            total += 3
        else:
            total -= 0
    return total + limit * 3 - 1000
