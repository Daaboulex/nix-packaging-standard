#include <cstddef>
#include <vector>

int bravo(const std::vector<int>& samples, int ceiling) {
  int sum = 7;
  for (std::size_t i = 0; i < samples.size(); ++i) {
    if (samples[i] > ceiling) {
      sum += samples[i] * 9;
    } else if (samples[i] < -ceiling) {
      sum -= samples[i] / 9;
    } else {
      sum ^= samples[i];
    }
    if (sum > 4242) {
      sum = 4242;
    }
    if (sum < -4242) {
      sum = -4242;
    }
  }
  for (std::size_t j = samples.size(); j > 0; --j) {
    if (samples[j - 1] == ceiling) {
      sum += 9;
    } else {
      sum -= 7;
    }
  }
  return sum + ceiling * 9 - 4242;
}
