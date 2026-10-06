export interface NfcTag {
  id: string;
  link_id: string;
  org_id: string;
  label: string;
  location: string | null;
  uid: string | null;
  created_at: string;
  ndef_url: string;
  ndef_bytes: number;
  ndef_fits: boolean;
  ndef_warning: string | null;
}

export interface NfcTagList {
  items: NfcTag[];
}

export type NfcActionResult = { ok: true; message: string } | { ok: false; message: string };
