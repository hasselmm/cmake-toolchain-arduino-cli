#include <Arduino.h>

void setup()
{
    Serial.begin(115200);
    Serial.println();
    Serial.println("CMakeBlink");

    pinMode(LED_BUILTIN, OUTPUT);
}

void loop()
{
    static auto blink = false;

    blink ^= true;
    digitalWrite(LED_BUILTIN, blink ? HIGH : LOW);
    delay(500);
}
