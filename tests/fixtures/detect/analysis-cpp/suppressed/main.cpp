int read(int* pointer) {
  return *pointer;
}

int main() {
  int* nothing = nullptr;
  return read(nothing);
}
