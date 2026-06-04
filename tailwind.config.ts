import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#191919",
        panel: "#202020",
        panel2: "#252525",
        border: "#2f2f2f",
        muted: "#9b9b9b",
      },
    },
  },
  plugins: [],
};

export default config;
