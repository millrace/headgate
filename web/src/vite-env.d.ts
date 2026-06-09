/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Base URL of the local headgate API. Defaults to http://localhost:10000. */
  readonly VITE_HEADGATE_API?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
