import { createApi, fetchBaseQuery } from "@reduxjs/toolkit/query/react";

export const TAG_TYPES = {
  NETWORKS: "Networks",
  BOARD: "Board",
  WLAN: "Wlan",
  ETHERNET: "Ethernet",
  FACTORY_NAME: "FactoryName",
  HOSTNAME: "Hostname",
  IOT_CLOUD_REGISTRATION: "IotCloudRegistration",
  FIRMWARE_AVAILABLE: "FirmwareAvailable",
  FIRMWARE_UPDATE: "FirmwareUpdate",
};

export const baseApi = createApi({
  reducerPath: "baseApi",
  baseQuery: fetchBaseQuery({ baseUrl: "/api/" }),
  tagTypes: Object.values(TAG_TYPES),
  endpoints: () => ({}),
});
