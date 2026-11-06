//! The machine's trusted root certificates (`LocalMachine\ROOT`), which every user and service on
//! the guest trusts.

use std::{ffi::OsString, io, os::windows::ffi::OsStringExt, ptr::null_mut, slice};

use windows_sys::Win32::Security::Cryptography::{
    CERT_CONTEXT, CERT_NAME_ATTR_TYPE, CERT_STORE_ADD_REPLACE_EXISTING, CERT_STORE_PROV_SYSTEM_W,
    CERT_SYSTEM_STORE_LOCAL_MACHINE, CertAddEncodedCertificateToStore, CertCloseStore,
    CertDeleteCertificateFromStore, CertDuplicateCertificateContext, CertEnumCertificatesInStore,
    CertFreeCertificateContext, CertGetNameStringW, CertOpenStore, HCERTSTORE, X509_ASN_ENCODING,
    szOID_COMMON_NAME,
};

use super::system::{check, wide};

#[derive(Debug)]
pub struct RootStore(HCERTSTORE);

/// A certificate the store handed out; it keeps its own reference, so it outlives enumeration.
#[derive(Debug)]
pub struct Certificate(*const CERT_CONTEXT);

impl RootStore {
    pub fn open() -> io::Result<RootStore> {
        let name = wide("ROOT");
        // SAFETY: the system provider takes the store name as a NUL-terminated UTF-16 string
        // (`wide`) that outlives the call; no crypto provider is passed.
        let store = unsafe {
            CertOpenStore(
                CERT_STORE_PROV_SYSTEM_W,
                0,
                0,
                CERT_SYSTEM_STORE_LOCAL_MACHINE,
                name.as_ptr().cast(),
            )
        };

        if store.is_null() {
            return Err(io::Error::last_os_error());
        }
        Ok(RootStore(store))
    }

    pub fn certificates(&self) -> Vec<Certificate> {
        let mut certificates = Vec::new();
        let mut previous: *const CERT_CONTEXT = null_mut();

        loop {
            // SAFETY: the store stays open while `self` lives; `previous` is null or the context
            // the last call returned, which this call frees.
            let next = unsafe { CertEnumCertificatesInStore(self.0, previous) };
            if next.is_null() {
                return certificates;
            }

            // SAFETY: `next` is a live context; the duplicate is a reference of its own, freed
            // when the `Certificate` drops.
            certificates.push(Certificate(unsafe {
                CertDuplicateCertificateContext(next)
            }));
            previous = next;
        }
    }

    /// One DER certificate; a certificate already in the store is replaced.
    pub fn add(&self, der: &[u8]) -> io::Result<()> {
        let length = u32::try_from(der.len())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;

        // SAFETY: the store stays open while `self` lives; `der` is `length` readable bytes; no
        // context is asked for back.
        check(unsafe {
            CertAddEncodedCertificateToStore(
                self.0,
                X509_ASN_ENCODING,
                der.as_ptr(),
                length,
                CERT_STORE_ADD_REPLACE_EXISTING,
                null_mut(),
            )
        })
    }

    pub fn delete(&self, certificate: &Certificate) -> io::Result<()> {
        // The delete frees the context it is given, even when it fails, so it gets a duplicate
        // and `certificate` keeps its own reference.
        // SAFETY: `certificate` holds a live context from this store.
        let duplicate = unsafe { CertDuplicateCertificateContext(certificate.0) };
        // SAFETY: `duplicate` is a live reference that only this call uses and frees.
        check(unsafe { CertDeleteCertificateFromStore(duplicate) })
    }
}

impl Drop for RootStore {
    fn drop(&mut self) {
        // SAFETY: the store was opened by `open`, and is closed once, here; contexts that are
        // still alive keep what they need.
        unsafe { CertCloseStore(self.0, 0) };
    }
}

impl Certificate {
    pub fn der(&self) -> &[u8] {
        // SAFETY: the context stays alive while `self` lives, and `pbCertEncoded` points at
        // `cbCertEncoded` bytes that it owns.
        unsafe {
            let context = &*self.0;
            slice::from_raw_parts(context.pbCertEncoded, context.cbCertEncoded as usize)
        }
    }

    /// The subject's common name; empty when it has none.
    pub fn common_name(&self) -> String {
        let oid = szOID_COMMON_NAME.cast();
        // SAFETY: the context stays alive while `self` lives; with no buffer the call returns the
        // length the name needs, its NUL included.
        let length =
            unsafe { CertGetNameStringW(self.0, CERT_NAME_ATTR_TYPE, 0, oid, null_mut(), 0) };

        let mut name = vec![0u16; length as usize];
        // SAFETY: as above, and `name` has room for `length` units.
        let written = unsafe {
            CertGetNameStringW(
                self.0,
                CERT_NAME_ATTR_TYPE,
                0,
                oid,
                name.as_mut_ptr(),
                length,
            )
        };

        let without_nul = (written as usize).saturating_sub(1).min(name.len());
        OsString::from_wide(&name[..without_nul])
            .to_string_lossy()
            .into_owned()
    }
}

impl Drop for Certificate {
    fn drop(&mut self) {
        // SAFETY: the context is the reference this `Certificate` took, freed once, here.
        unsafe { CertFreeCertificateContext(self.0) };
    }
}
