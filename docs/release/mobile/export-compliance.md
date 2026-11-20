# Mobile encryption and export compliance

This is not legal advice. The maintainer must confirm the classification of the actual archive and the requirements for each distribution territory before TestFlight or App Store distribution.

## What the app uses

RelayBar ships an SSH client built with the open-source swift-nio-ssh library. SSH negotiates keys and encrypts SFTP traffic and forwarded streams. Its protocol implementation ships in the app. HTTPS uses the system TLS implementation. The device’s Secure Enclave signs with a P-256 key. The Keychain can hold a saved password.

## App Store Connect questions

- Does the app use, contain or incorporate encryption? Yes. SSH protects the contents transferred as well as authenticating the connection.
- What is the app’s purpose, and does an exemption apply? Describe remote file reading and SSH forwarding. The maintainer must assess any exemption against those uses.
- Does it implement proprietary or non-standard algorithms, standard algorithms outside or alongside the operating system, both, or neither? The bundled SSH implementation uses standard cryptography. No proprietary algorithm is identified in the design. Verify the linked dependencies and algorithms in the archive before choosing the answer.
- Will the app be distributed in France? Answer for the intended territories. Apple lists a French declaration for distribution in France with standard encryption supplied outside the operating system. [Apple’s documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)

## Maintainer decision

Determine the applicable US classification, exemption and any filing or reporting duties. Confirm any French declaration and retain the basis for the answers. Complete the App Encryption Documentation questionnaire and supply any required documents once submission is authorised. Match the archive’s `ITSAppUsesNonExemptEncryption` declaration to the confirmed result and include Apple’s compliance code if issued. [Apple’s export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) · [App Store Connect filing steps](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation/)
