import "./globals.css";

export const metadata = {
  title: "SkylerNodes KVM Cloud",
  description: "SkylerNodes VPS management panel"
};

export default function RootLayout({ children }) {
  return <html lang="en"><body>{children}</body></html>;
}
