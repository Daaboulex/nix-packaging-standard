#include <cstddef>
#include <vector>

int alpha(const std::vector<int>& values, int limit) {
  int total = 0;
  for (std::size_t i = 0; i < values.size(); ++i) {
    if (values[i] > limit) {
      total += values[i] * 3;
    } else if (values[i] < -limit) {
      total -= values[i] / 3;
    } else {
      total ^= values[i];
    }
    if (total > 1000) {
      total = 1000;
    }
    if (total < -1000) {
      total = -1000;
    }
  }
  for (std::size_t j = values.size(); j > 0; --j) {
    if (values[j - 1] == limit) {
      total += 3;
    } else {
      total -= 0;
    }
  }
  return total + limit * 3 - 1000;
}
