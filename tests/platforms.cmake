if (NOT ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
    set(ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS
        ATTinyCore:avr:attiny1634
        ATTinyCore:avr:attiny43
        ATTinyCore:avr:attiny828
        ATTinyCore:avr:attinyx313
        ATTinyCore:avr:attinyx4
        ATTinyCore:avr:attinyx41
        ATTinyCore:avr:attinyx5
        ATTinyCore:avr:attinyx7
        ATTinyCore:avr:attinyx8
        STMicroelectronics:stm32:Nucleo_64:pnum=NUCLEO_F103RB
        arduino:avr:nano
        arduino:samd:nano_33_iot
        esp32:esp32:nodemcu-32s
        esp8266:esp8266:nodemcuv2)
endif()
