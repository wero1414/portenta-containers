#!/usr/bin/env python3
#
# Arduino Lora node python source code
#
# Tested with:
# Python 3.8.5
# pyserial-3.4
# lora modem fw 1.2.1
# lora gateway Multi-channel DIY gateway Raspberry Pi with IMST iC880A GP 901 C
#
# Application description:
# a simple lora node that send a small custom packet containing temperature and humidity values
# gathered from an i2c sensor connected to the ext. m4 controller. The data is then forwarded by
# the lora gateway to The Things Network cloud.
#
# To obtain modem EUI run this script passing "deviceinfo" as argument
#
# Created by Massimo Pennazio <maxipenna@libero.it> and K Ho Chung <k.hochung@arduino.cc> 2022

import logging
import serial
import time
import queue
import sys
import struct

from at_protocol import ATProtocol
from msgpackrpc import Address as RpcAddress, Client as RpcClient, error as RpcError

import os
from dotenv import load_dotenv
from periphery import GPIO
from cayennelpp import LppFrame

# M4 Proxy Server Configuration
# Fixed configuration parameters
port = 8884
publish_interval = 5

# The M4 Proxy address needs to be mapped via Docker's extra hosts
m4_proxy_address = 'm4-proxy'
m4_proxy_port = 5001

# Use to skip actual rpc communication and send test data
m4_emulation = True

### Class definition
class modemLora(ATProtocol):

    TERMINATOR = b'\r'

    loraBand = {
        "AS923": 0,
        "AU915": 1,
        "EU868": 5,
        "KR920": 6,
        "IN865": 7,
        "US915": 8,
        "US915_HYBRID": 9
    }

    loraRfMode = {
        "RFO": 0,
        "PABOOST": 1
    }

    loraMode = {
        "ABP": 0,
        "OTAA": 1
    }

    rfProperty = {
        "APP_EUI": "AT+APPEUI=",
        "APP_KEY": "AT+APPKEY=",
        "DEV_EUI": "AT+DEVEUI=",
        "DEV_ADDR": "AT+DEVADDR=",
        "NWKS_KEY": "AT+NWKSKEY=",
        "NWK_ID": "AT+IDNWK=",
        "APPS_KEY": "AT+APPSKEY="
    }

    loraClass = {
        "CLASS_A": 'A',
        "CLASS_B": 'B',
        "CLASS_C": 'C'
    }

    def __init__(self):
        logging.debug("Method __init__ called")
        super(modemLora, self).__init__()
        self.event_responses = queue.Queue()
        self._awaiting_response_for = None

    def connection_made(self, transport):
        logging.debug("Method connection_made called")
        super(modemLora, self).connection_made(transport)
        logging.debug("Resetting the modem")
        modem_rst = GPIO("/dev/gpiochip5", 3, "out") # 163 in /sys/class/gpio/export, PF4 on ext. stm32h7
        modem_rst.write(True)
        time.sleep(0.1)
        modem_rst.write(False)
        time.sleep(0.1)
        modem_rst.write(True)
        time.sleep(0.3) # Waiting for modem to became alive @TODO: wait for something written on serial port?
        logging.debug("Modem is alive...")
        self.transport.serial.reset_input_buffer() # Flush input data written by modem during startup

    def handle_event(self, event):
        """Handle events and command responses starting with '+...'"""
        if event.startswith('+OK') and self._awaiting_response_for.endswith('AT'):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK=') and self._awaiting_response_for.startswith('AT+DEV?'):
            resp = event[4:4 + 7]
            self.event_responses.put(resp.encode())
        elif event.startswith('+OK=') and self._awaiting_response_for.startswith('AT+VER?'):
            resp = event[4:4 + 5]
            self.event_responses.put(resp.encode())
        elif event.startswith('+OK=') and self._awaiting_response_for.startswith('AT+DEVEUI?'):
            resp = event[4:4 + 16]
            self.event_responses.put(resp.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+BAND='):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+MODE='):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+APPEUI='):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+APPKEY='):
            self.event_responses.put(event.encode())
        elif event.startswith('+ACK') and self._awaiting_response_for.startswith('AT+JOIN'):
            logging.debug("Received +ACK")
        elif event.startswith('+EVENT=1,1') and self._awaiting_response_for.startswith('AT+JOIN'):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+CTX'):
            self.event_responses.put(event.encode())
        elif event.startswith('+OK') and self._awaiting_response_for.startswith('AT+UTX'):
            self.event_responses.put(event.encode())
        elif event.startswith('+ERR'):
            logging.error("Modem error!")
            self.event_responses.put(event.encode())
        elif event.startswith('+RRBDRES') and self._awaiting_response_for.startswith('AT+JRBD'):
            rev = event[9:9 + 12]
            mac = ':'.join('{:02X}'.format(ord(x)) for x in rev.decode('hex')[::-1])
            self.event_responses.put(mac)
        else:
            logging.warning('unhandled event: {!r}'.format(event))

    def command_with_event_response(self, command, timeout=5):
        """Send a command that responds with '+...' line"""
        logging.debug("Sending command %s with response +..." % command)
        with self.lock:  # Ensure that just one thread is sending commands at once
            self._awaiting_response_for = command
            self.transport.write(command.encode(self.ENCODING, self.UNICODE_HANDLING) + self.TERMINATOR)
            response = self.event_responses.get(timeout=timeout)
            self._awaiting_response_for = None
            return response

    def bytes_with_event_response(self, command, payload, timeout=5):
        """Send a command that responds with '+...' line"""
        logging.debug("Sending command %s with response +..." % command)
        with self.lock:  # Ensure that just one thread is sending commands at once
            self._awaiting_response_for = command
            self.transport.write(command.encode(self.ENCODING, self.UNICODE_HANDLING) + self.TERMINATOR)
            self.transport.write(payload)
            response = self.event_responses.get(timeout=timeout)
            self._awaiting_response_for = None
            return response

    # - - - example commands

    def ping(self):
        return self.command_with_event_response("AT")

    def deviceVersion(self):
        return self.command_with_event_response("AT+DEV?")

    def firmwareVersion(self):
        return self.command_with_event_response("AT+VER?")

    def deviceEUI(self):
        return self.command_with_event_response("AT+DEVEUI?")

    def configureBand(self, band):
        value = self.loraBand[band]
        return self.command_with_event_response("AT+BAND=" + str(value))

    def changeMode(self, mode):
        value = self.loraMode[mode]
        return self.command_with_event_response("AT+MODE=" + str(value))

    def changeProperty(self, what, value):
        propertyCmd = self.rfProperty[what]
        return self.command_with_event_response(propertyCmd + str(value))

    def join(self, timeout):
        return self.command_with_event_response("AT+JOIN", timeout)

    def joinOTAA(self, appEui, appKey, devEui=None):
        print("Changing mode to %s: %s" % ("OTAA", self.changeMode("OTAA")))
        print("Changing property %s to %s: %s" % ("APP_EUI", appEui, self.changeProperty("APP_EUI", appEui)))
        print("Changing property %s to %s: %s" % ("APP_KEY", appKey, self.changeProperty("APP_KEY", appKey)))
        if devEui is not None:
            print("Changing property %s to %s: %s" % ("DEV_EUI", devEui, self.changeProperty("DEV_EUI", devEui)))
        print("Joining...")
        print("%s" % self.join(60)) # Timeout of 1 minute to connect

    def sendBytes(self, payload, size, confirmed=False):
        if confirmed:
            return self.bytes_with_event_response("AT+CTX " + str(size), payload)
        else:
            return self.bytes_with_event_response("AT+UTX " + str(size), payload)

### End ATProtocol class definition

def get_data_from_m4():
    """Get data from the M4 via RPC (MessagePack-RPC)

    The Arduino sketch on the M4 must implement the following methods
    returning the suitable values from the attached sensor:

    * `temperature`

    """

    rpc_address = RpcAddress(m4_proxy_address, m4_proxy_port)

    data = ()

    try:
        rpc_client = RpcClient(rpc_address)
        temperature = rpc_client.call('temperature')

        rpc_client = RpcClient(rpc_address)
        humidity = rpc_client.call('humidity')

        data = temperature, humidity

    except RpcError.TimeoutError:
        print("Unable to retrive data from the M4.")

    return data

# Print unique Device EUI from modem,
# then associate it with the cloud application
def deviceinfo():
    with serial.threaded.ReaderThread(ser, modemLora) as lora_module:
        print("Pinging modem: %s" % lora_module.ping())
        print("Device version: %s" % lora_module.deviceVersion())
        print("Firmware version: %s" % lora_module.firmwareVersion())
        print("Device EUI: %s" % lora_module.deviceEUI())

def application(band="EU868"):
    # Obtained during first registration of the device
    SECRET_APP_EUI = ''
    SECRET_APP_KEY = ''

    # Retrieve data from m4 processor running custom arduino sketch
    data = ()
    if m4_emulation is False:
        data = get_data_from_m4()
    if len(data) > 0:
        print("Temperature: ", data[0])
        print("Humidity [%]", data[1])
    else:
        # Default Data Set - For testing purposes only
        data = [25.57, 60.05]

    with serial.threaded.ReaderThread(ser, modemLora) as lora_module:
        print("Pinging modem: %s" % lora_module.ping())
        print("Device version: %s" % lora_module.deviceVersion())
        print("Firmware version: %s" % lora_module.firmwareVersion())
        print("Device EUI: %s" % lora_module.deviceEUI())
        print("Setting band %s: %s" % (band, lora_module.configureBand(band)))
        time.sleep(5)

        lora_module.joinOTAA(SECRET_APP_EUI, SECRET_APP_KEY)
        print("Welcome to TTN >>")

        # Sending received sensor data
        frame = LppFrame()
        frame.add_temperature(0, data[0])
        frame.add_humidity(1, data[1])

        payload = bytes(frame)
        lora_module.sendBytes(payload, len(payload), False)

### Main program
if __name__ == '__main__':
    logging.basicConfig(stream = sys.stdout,
                format = "%(levelname)s %(asctime)s - %(message)s",
                level = logging.DEBUG)

    load_dotenv(dotenv_path="/run/arduino_hw_info.env")

    if os.environ['CARRIER_NAME'] != "max":
        print("This script requires Max carrier")
        exit(1)

    logging.info("============================================")
    logging.info("Started lora-node")
    logging.info("============================================")

    ser = serial.Serial()
    ser.baudrate = 19200
    ser.port = '/dev/ttymxc3'
    ser.bytesize = 8
    ser.parity = 'N'
    ser.stopbits = 2
    ser.timeout = 1
    logging.debug("Configured serial port with:\n\r%s" % str(ser))
    logging.debug("Opening serial port")

    band = "EU868"

    try:
        ser.open()
    except Exception as e:
        logging.error("error open serial port: " + str(e))
        exit()

    if len(sys.argv) > 1:
        if sys.argv[1] == "deviceinfo":
            deviceinfo()
    else:
        application(band)

### End Main program