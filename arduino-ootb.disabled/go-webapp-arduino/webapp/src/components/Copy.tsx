import React, { useState } from "react";
import copy from "copy-to-clipboard";
import Box from "@mui/material/Box";
import { SvgCopy } from "../assets/Copy";

interface CopyProps {
  value: string;
  backgroundColor?: string;
  children: React.ReactNode | React.ReactNode[];
}

function CopyComponent(props: CopyProps) {
  const { value, children, backgroundColor } = props;
  const [copied, setCopied] = useState(false);

  return (
    <Box
      tabIndex={0}
      className="Oob-Copy"
      sx={{
        display: "flex",
        "&:hover": {
          ".copy": {
            opacity: 1,
          },
        },
      }}
    >
      {children}
      <Box
        sx={{
          position: "relative",
          color: "secondary.main",
          fontWeight: 700,
          fontFamily: "Roboto Mono",
          ">.MuiBox-root": {
            display: "flex",
            alignItems: "center",
            cursor: "pointer",
            backgroundColor: backgroundColor ?? "#2F2F2F",
            position: "absolute",
            left: 0,
            top: "50%",
            transform: "translateY(-50%)",
            transition: (theme) =>
              theme.transitions.create(["opacity"], { duration: 200 }),
          },
        }}
      >
        <Box
          className="copied"
          sx={{
            pointerEvents: "none",
            zIndex: 101,
            opacity: copied ? 1 : 0,
            transition: (theme) =>
              theme.transitions.create(["opacity"], { duration: 200 }),
            svg: { height: 20, marginRight: 1 },
          }}
        >
          <SvgCopy />
          {"Copied!"}
        </Box>
        <Box
          className="copy"
          onClick={() => {
            copy(value);
            setCopied(true);
            setTimeout(() => {
              setCopied(false);
            }, 3000);
          }}
          sx={{
            zIndex: 100,
            opacity: 0,
            svg: { height: 20, marginRight: 1 },
          }}
        >
          <SvgCopy />
          {"Copy"}
        </Box>
      </Box>
    </Box>
  );
}

export const Copy = React.memo(CopyComponent);
