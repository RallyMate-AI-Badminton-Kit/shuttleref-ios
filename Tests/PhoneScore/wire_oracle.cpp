#include "phone_score_protocol.h"
#include <iostream>
#include <string>
int main() {
    std::string line; unsigned count = 0;
    while (std::getline(std::cin, line)) {
        phonescore::Command command;
        if (!phonescore::decode(line.data(), line.size(), command)) return 1;
        ++count;
    }
    std::cout << "PASS firmware parser accepted " << count << " App control vectors\n";
    return count == 4 ? 0 : 1;
}
