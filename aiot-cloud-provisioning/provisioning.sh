#!/bin/sh

# NOTES:
# - Production api: https://api2.arduino.cc/iot/v1
# - Devel api: https://api-dev.arduino.cc/iot/v2

# Functions
device_provisioning()
{
    JSONFILE=$1
    CLIENT_ID=$2
    CLIENT_SECRET=$3

    echo $JSONFILE
    set -ex
    # Generate a private key compatible with ArduinoIoTCloud
    pkcs11-tool --module /usr/lib/libckteec.so.0 --init-token --label arduino --so-pin 12345678
    pkcs11-tool --module /usr/lib/libckteec.so.0 --init-pin --label arduino --so-pin 12345678 --pin 87654321
    pkcs11-tool --module /usr/lib/libckteec.so.0 --keypairgen --key-type EC:prime256v1 --label device-priv-key --token-label arduino --pin 87654321
    # Get private key URI
    p11tool --provider=/usr/lib/libckteec.so.0 --list-tokens
    p11tool --provider=/usr/lib/libckteec.so.0 --list-all pkcs11:model=OP-TEE%20TA;manufacturer=Linaro;serial=0000000000000000;token=arduino
    # Provision the device
    ## Get an usable token from the cloud
    RESPONSE=$(curl --location --request POST "https://api-dev.arduino.cc/iot/v1/clients/token" \
    --header "content-type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    --data-urlencode "audience=https://api2.arduino.cc/iot")
    echo "Response: $RESPONSE"
    ACCESS_TOKEN=$(echo $RESPONSE | jq '.access_token' | tr -d '"')
    res=$?
    if [ $res -eq 0 ]; then
        echo "ACCESS_TOKEN: success"
        echo ACCESS_TOKEN=$ACCESS_TOKEN
    else
        echo "ACCESS_TOKEN: fail"
        return 1
    fi

    NAME=$(cat $JSONFILE | jq '.name' | tr -d '"')
    res1=$?
    TYPE=$(cat $JSONFILE | jq '.type' | tr -d '"')
    res2=$?
    if [ $res1 -eq 0 ] && [ $res2 -eq 0 ]; then
        echo "NAME and TYPE success"
    else
        echo "Failed to obtain NAME and TYPE from json file, aborting"
        return 1
    fi

    ## Get a device id from the cloud
    RESPONSE=$(curl --location --request PUT "https://api-dev.arduino.cc/iot/v2/devices" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --header "Content-Type: application/json" \
    --data-raw "{\"name\": \"${NAME}\",\"type\": \"${TYPE}\"}")
    echo "Response: $RESPONSE"
    DEVICE_ID=$(echo $RESPONSE | jq '.id' | tr -d '"')
    res=$?
    if [ $res -eq 0 ]; then
        echo "DEVICE_ID: success"
        echo DEVICE_ID=$DEVICE_ID
    else
        echo "DEVICE_ID: fail"
        return 1
    fi

    ## Generate CSR
    OPENSSL_CONF=./openssl.conf openssl req -new -engine pkcs11 -keyform engine -passin pass:87654321 -key label_device-priv-key -out csr.csr -subj "/CN=${DEVICE_ID}"
    res=$?
    if [ $res -eq 0 ]; then
        echo "Generate CSR: success"
        CSR=$(cat csr.csr | awk '{print $0"\\n"}' | tr -d '\n')
    else
        echo "Generate CSR: fail"
        return 1
    fi

    ## Get device certificate
    RESPONSE=$(curl --location --request PUT "https://api-dev.arduino.cc/iot/v2/devices/${DEVICE_ID}/certs" \
    --header "Accept: application/json" \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-raw "{\"ca\":\"Arduino\",\"csr\":\"${CSR}\",\"enabled\":true}")
    echo "Response: $RESPONSE"
    DEVICE_CERT=$(echo $RESPONSE | jq '.pem' | tr -d '"')
    res=$?
    if [ $res -eq 0 ]; then
        echo "DEVICE_CERT: success"
        echo DEVICE_CERT=$DEVICE_CERT
    else
        echo "DEVICE_CERT: fail"
        return 1
    fi

    ## Create device certificate der file
    echo $DEVICE_CERT | sed 's/\\n/\n/g' > device-certificate.pem
    openssl x509 -outform DER -in device-certificate.pem -out device-certificate.der

    ## Store device certificate
    pkcs11-tool --module /usr/lib/libckteec.so.0  --login --pin 87654321 --write-object device-certificate.der --type cert --slot 0 --label device-certificate

    ## Update json file with DEVICE_ID
    cat $JSONFILE | jq --arg device_id "$DEVICE_ID" '.device_id |= $device_id' > /tmp/iot-secrets.json
    res=$?
    if [ $res -eq 0 ]; then
        cp /tmp/iot-secrets.json $JSONFILE
        echo "Updated json file $JSONFILE correctly"
    else
        echo "Failed to update json file $JSONFILE"
        return 1
    fi

    return 0
}

create_tpm_key()
{
    SO_PIN=$1
    PIN=$2
    SLOT=$3
    # Initialize Arduino token. This will erase all the data stored.
    pkcs11-tool --module /usr/lib/libckteec.so.0 --init-token --slot-index $SLOT --label arduino --so-pin $SO_PIN
    res=$?
    if [ $res -eq 0 ]; then
        :
    else
        echo "Failed to initialize Arduino token"
        return 1
    fi
    # Setup user PIN
    pkcs11-tool --module /usr/lib/libckteec.so.0 --init-pin --token-label arduino --so-pin $SO_PIN --pin $PIN
    res=$?
    if [ $res -eq 0 ]; then
        :
    else
        echo "Failed to configure user PIN"
        return 1
    fi
    # Generate device keypair
    pkcs11-tool --module /usr/lib/libckteec.so.0 --keypairgen --token-label arduino --key-type EC:prime256v1 --label device-key --id 0 --pin $PIN
    res=$?
    if [ $res -eq 0 ]; then
        :
    else
        echo "Failed to generate device keypair"
        return 1
    fi
    # Get key pkcs11 URI
    URI=$(p11tool --only-urls --provider=/usr/lib/libckteec.so.0 --list-all pkcs11:token=arduino;object=device-key)
    res=$?
    if [ $res -eq 0 ]; then
        URI=$(echo $URI | sed 's/object=device-key.*/object=device-key/')
    else
        echo "Failed to get key URI"
        return 1
    fi
    #  Update json file with device key URI
    cat $JSONFILE | jq --arg key_uri "$URI" '.key_uri |= $key_uri' > /tmp/iot-secrets.temp
    res=$?
    if [ $res -eq 0 ]; then
        cp /tmp/iot-secrets.temp $JSONFILE
        rm /tmp/iot-secrets.temp
        echo "Updated json file $JSONFILE correctly"
    else
        echo "Failed to update json file $JSONFILE"
        return 1
    fi

    return 0
}

create_csr()
{
    PIN=$1
    DEVICE_ID=$2
    # Generate CSR
    OPENSSL_CONF=./openssl.conf openssl req -new -engine pkcs11 -keyform engine -passin pass:$PIN -key label_device-key -out /tmp/csr.csr -subj "/CN=${DEVICE_ID}"
    res=$?
    if [ $res -eq 0 ]; then
        echo "Generate CSR: success"
        CSR=$(cat /tmp/csr.csr | awk '{print $0"\\n"}' | tr -d '\n')
        echo $CSR
    else
        echo "Generate CSR: fail"
        return 1
    fi
    return 0
}

store_certificate()
{
    PIN=$1
    CERT=$2
    SLOT=$3

    # Create device certificate der file
    echo $CERT | sed 's/\\n/\n/g' > device-certificate.pem
    openssl x509 -outform DER -in device-certificate.pem -out device-certificate.der

    # Store device certificate
    pkcs11-tool --module /usr/lib/libckteec.so.0  --login --pin $PIN --write-object device-certificate.der --type cert --slot $SLOT --label device-certificate
    return 0
}

create_thing()
{
    CLIENT_ID=$1
    CLIENT_SECRET=$2
    THING_NAME=$3
    DEVICE_ID=$4
    DASHBOARD_NAME=$THING_NAME

    # Create a new thing from tempalte
    THING_ID=$(ARDUINO_CLOUD_CLIENT=$CLIENT_ID ARDUINO_CLOUD_SECRET=$CLIENT_SECRET arduino-cloud-cli thing create --name $THING_NAME --template thing-template.yml --format json | jq .id | tr -d '"')
    if [ $? -eq 0 ] && [ -n "$THING_ID" ]; then
        echo
        echo ACCESS_TOKEN=$THING_ID
    else
        echo "THING_ID: fail"
        return 1
    fi

    # Bind thing to the board device_id
    ARDUINO_CLOUD_CLIENT=$CLIENT_ID ARDUINO_CLOUD_SECRET=$CLIENT_SECRET arduino-cloud-cli thing bind --id $THING_ID --device-id $DEVICE_ID
    if [ $? -eq 0 ]; then
        echo
    else
        echo "BIND: fail"
        return 1
    fi

    # Create a new dashboard from template
    ARDUINO_CLOUD_CLIENT=$CLIENT_ID ARDUINO_CLOUD_SECRET=$CLIENT_SECRET arduino-cloud-cli dashboard create --name $DASHBOARD_NAME --template dashboard-template.yml --override x8-template=$THING_ID
    if [ $? -eq 0 ]; then
        echo
    else
        echo "DASHBOARD: fail"
        return 1
    fi

    return 0
}

usage()
{
    echo "Usage:"
    echo "$0 -kcstf arg1...argN"
    echo "k: <so_pin> <pin> <slot_index> Initialize TPM token <slot_index> and user <pin>. Create EC:prime256v1 keypair"
    echo "c: <pin> <device_id> create csr with tpm key and device_id"
    echo "s: <pin> <certificate> <slot> store certificate in der format into tpm"
    echo "t: <client_id> <client_secret> <thing_name> <device_id> create thing obj on aiot cloud for a given device_id"
    echo "f: <client_id> <client_secret> do the provisioning using default values"
}

# Main
echo "$0: Started"

#JSONFILE="/var/sota/iot-secrets.json"
#TEMPLATE="/iot-secrets.template"
JSONFILE="/tmp/iot-secrets.json"
TEMPLATE="./iot-secrets.template"

if [ ! -f $JSONFILE ]; then
    echo "Creating $JSONFILE for the first time..."
    cp $TEMPLATE $JSONFILE

    # Update template file with unique name for this device
    NAME="portenta-x8-"$(cat /sys/devices/soc0/serial_number)
    cat $TEMPLATE | jq --arg name "$NAME" '.name |= $name' > $JSONFILE
fi

res=1
while getopts "k:c:s:t:f:" arg; do
    case $arg in
        k)
            if [ $# -ne 4 ]; then
                echo "Please provide SO_PIN PIN and SLOT as cmd line args"
                usage
                break
            fi
            SO_PIN=$2
            PIN=$3
            SLOT=$4
            echo "create_tpm_key $SO_PIN $PIN $SLOT"
            create_tpm_key $SO_PIN $PIN $SLOT
            res=$?
            ;;
        c)
            if [ $# -ne 3 ]; then
                echo "Please provide tpm user PIN and DEVICE_ID as cmd line args"
                usage
                break
            fi
            PIN=$2
            DEVICE_ID=$3
            echo "create_csr $PIN $DEVICE_ID"
            create_csr $PIN $DEVICE_ID
            res=$?
            ;;
        s)
            if [ $# -ne 4 ]; then
                echo "Please provide PIN, CERT and SLOT as cmd line args"
                usage
                break
            fi
            PIN=$2
            CERT=$3
            SLOT=$4
            #store_certificate $PIN $CERT $SLOT
            res $?
            ;;
        t)
            if [ $# -ne 5 ]; then
                echo "Please provide CLIENT_ID, CLIENT_SECRET, THING_NAME and DEVICE_ID as cmd line args"
                usage
                break
            fi
            CLIENT_ID=$2
            CLIENT_SECRET=$3
            THING_NAME=$4
            DEVICE_ID=$5
            create_thing $CLIENT_ID $CLIENT_SECRET $THING_NAME $DEVICE_ID
            res=$?
            ;;
        f)
            if [ $# -ne 3 ]; then
                echo "Please provide CLIENT_ID and SECRET_ID as cmd line args"
                usage
                break
            fi
            CLIENT_ID=$2
            CLIENT_SECRET=$3
            #device_provisioning $JSONFILE $CLIENT_ID $CLIENT_SECRET
            res=$?
            ;;
        *)
            usage
            ;;
    esac
done

if [ $res -ne 0 ]; then
    echo "Failed, please change settings and retry"
else
    echo "Success"
fi

echo "$0: Ended"

exit $res
