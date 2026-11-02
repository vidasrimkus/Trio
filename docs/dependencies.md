# Dependencies of vidasrimkus/Trio

Machine-readable list of every git submodule and Swift Package the app build needs, with the exact revision
that is pinned. t1d-monitor's daily availability check reads the JSON block below (`sed -n '/^```json/,/^```$/p' | sed '1d;$d'`)
and sends a HEAD request to every `url`; for submodules it also checks that `pinned_commit` still exists.

Regenerate after any submodule or package change: `node <this script>` is not checked in — the file was produced
from `.gitmodules`, `git ls-tree HEAD` and the two `Package.resolved` files; keep the same shape.

`forked_from` marks the repos we host ourselves (CUSTOMIZATIONS.md §9); the pinned commit is the same as upstream's.

```json
{
  "generated_from": "feature/log-shipper 5c6b74a84",
  "generated_at": "2026-11-02",
  "check": "HEAD https://github.com/<owner>/<repo> must answer 200; for submodules also GET https://api.github.com/repos/<owner>/<repo>/commits/<pinned_commit> must answer 200",
  "submodules": [
    {
      "name": "LoopKit",
      "path": "LoopKit",
      "url": "https://github.com/vidasrimkus/LoopKit.git",
      "branch": null,
      "pinned_commit": "d52c298e3e3fe640e2ae1c5cef885da5daaa58cb",
      "forked_from": "https://github.com/loopandlearn/LoopKit.git"
    },
    {
      "name": "CGMBLEKit",
      "path": "CGMBLEKit",
      "url": "https://github.com/loopandlearn/CGMBLEKit.git",
      "branch": null,
      "pinned_commit": "7b660d22a447a6ea5e800dbb30b2c1b13864f5bc"
    },
    {
      "name": "dexcom-share-client-swift",
      "path": "dexcom-share-client-swift",
      "url": "https://github.com/loopandlearn/dexcom-share-client-swift.git",
      "branch": null,
      "pinned_commit": "0f71fa2a450f55a92cff62e183d87c86b9c6633a"
    },
    {
      "name": "RileyLinkKit",
      "path": "RileyLinkKit",
      "url": "https://github.com/loopandlearn/RileyLinkKit",
      "branch": null,
      "pinned_commit": "7ac340a4c3a3ec18e16264d0468474b04485ce8f"
    },
    {
      "name": "G7SensorKit",
      "path": "G7SensorKit",
      "url": "https://github.com/loopandlearn/G7SensorKit.git",
      "branch": null,
      "pinned_commit": "c2abb4f096351271909c358f4d4212bb92575700"
    },
    {
      "name": "MinimedKit",
      "path": "MinimedKit",
      "url": "https://github.com/loopandlearn/MinimedKit.git",
      "branch": null,
      "pinned_commit": "a9bf9ea5f6d882dfd48179c0f696fc7b27ec196a"
    },
    {
      "name": "LibreTransmitter",
      "path": "LibreTransmitter",
      "url": "https://github.com/loopandlearn/LibreTransmitter.git",
      "branch": null,
      "pinned_commit": "125745be2ac82f42a2d2f4e11f639ef624c9cd37"
    },
    {
      "name": "TidepoolService",
      "path": "TidepoolService",
      "url": "https://github.com/loopandlearn/TidepoolService.git",
      "branch": null,
      "pinned_commit": "986c08203f12bdf1b28b231e448091f9abaaa389"
    },
    {
      "name": "DanaKit",
      "path": "DanaKit",
      "url": "https://github.com/vidasrimkus/DanaKit",
      "branch": null,
      "pinned_commit": "a2d3aa45810259283322c9af834fda181860b3ee",
      "forked_from": "https://github.com/loopandlearn/DanaKit"
    },
    {
      "name": "MedtrumKit",
      "path": "MedtrumKit",
      "url": "https://github.com/loopandlearn/MedtrumKit",
      "branch": null,
      "pinned_commit": "afa2485ac9ae7cf275de09f3c3f7a8718486514e"
    },
    {
      "name": "OmnipodKit",
      "path": "OmnipodKit",
      "url": "https://github.com/vidasrimkus/OmnipodKit",
      "branch": null,
      "pinned_commit": "4e923d77695cbff9983ef1c252a785d7af588300",
      "forked_from": "https://github.com/loopandlearn/OmnipodKit"
    },
    {
      "name": "AccuChekKit",
      "path": "AccuChekKit",
      "url": "https://github.com/loopandlearn/AccuChekKit",
      "branch": null,
      "pinned_commit": "e9641779196300ca2d7699e2e69eb881be0c6fe5"
    },
    {
      "name": "EversenseKit",
      "path": "EversenseKit",
      "url": "https://github.com/loopandlearn/EversenseKit",
      "branch": null,
      "pinned_commit": "063eb66e21e1555edf45e01548ab948af6a79519"
    },
    {
      "name": "LibreCRKit",
      "path": "LibreCRKit",
      "url": "https://github.com/vidasrimkus/LibreCRKit.git",
      "branch": "trio",
      "pinned_commit": "24d5617f703089a36f4261c3ab84f2ac505a8f1a",
      "forked_from": "https://github.com/pov-it/LibreCRKit.git"
    },
    {
      "name": "LibreLoop",
      "path": "LibreLoop",
      "url": "https://github.com/loopandlearn/LibreLoop.git",
      "branch": "trio",
      "pinned_commit": "d98a9ee52398c1e867f7c044b1dc10e6aaa8fce0"
    },
    {
      "name": "LoopAlgorithm",
      "path": "LoopAlgorithm",
      "url": "https://github.com/vidasrimkus/LoopAlgorithm.git",
      "branch": null,
      "pinned_commit": "7d016fb55ded96ef25ef612a153c69a9c911ca19",
      "forked_from": "https://github.com/loopandlearn/LoopAlgorithm.git"
    }
  ],
  "spm_packages": [
    {
      "name": "abseil-cpp-binary",
      "url": "https://github.com/google/abseil-cpp-binary.git",
      "version": "1.2024072200.0",
      "branch": null,
      "revision": "bbe8b69694d7873315fd3a4ad41efe043e1c07c5"
    },
    {
      "name": "app-check",
      "url": "https://github.com/google/app-check.git",
      "version": "11.2.0",
      "branch": null,
      "revision": "61b85103a1aeed8218f17c794687781505fbbef5"
    },
    {
      "name": "asn1",
      "url": "https://github.com/leif-ibsen/ASN1",
      "version": "2.7.0",
      "branch": null,
      "revision": "e38d1b8b43d8b53ffadde9836f34289176bb7a0c"
    },
    {
      "name": "bigint",
      "url": "https://github.com/leif-ibsen/BigInt",
      "version": "1.24.0",
      "branch": null,
      "revision": "7c7b1be2f6714ce03833879b0aab4b20293c0207"
    },
    {
      "name": "bluecryptor",
      "url": "https://github.com/Kitura/BlueCryptor.git",
      "version": "2.0.2",
      "branch": null,
      "revision": "cec97c24b111351e70e448972a7d3fe68a756d6d"
    },
    {
      "name": "blueecc",
      "url": "https://github.com/Kitura/BlueECC.git",
      "version": "1.2.201",
      "branch": null,
      "revision": "1485268a54f8135435a825a855e733f026fa6cc8"
    },
    {
      "name": "bluersa",
      "url": "https://github.com/Kitura/BlueRSA.git",
      "version": "1.0.203",
      "branch": null,
      "revision": "f40325520344a966523b214394aa350132a6af68"
    },
    {
      "name": "connectiq-companion-app-sdk-ios",
      "url": "https://github.com/garmin/connectiq-companion-app-sdk-ios",
      "version": "1.8.0",
      "branch": null,
      "revision": "f0d29ff691d700a132d86205ed9bb091e336c2f7"
    },
    {
      "name": "cryptoswift",
      "url": "https://github.com/krzyzanowskim/CryptoSwift",
      "version": "1.8.2",
      "branch": null,
      "revision": "c9c3df6ab812de32bae61fc0cd1bf6d45170ebf0"
    },
    {
      "name": "firebase-ios-sdk",
      "url": "https://github.com/firebase/firebase-ios-sdk.git",
      "version": "11.15.0",
      "branch": null,
      "revision": "fdc352fabaf5916e7faa1f96ad02b1957e93e5a5"
    },
    {
      "name": "google-ads-on-device-conversion-ios-sdk",
      "url": "https://github.com/googleads/google-ads-on-device-conversion-ios-sdk",
      "version": "2.3.0",
      "branch": null,
      "revision": "a2d0f1f1666de591eb1a811f40b1706f5c63a2ed"
    },
    {
      "name": "googleappmeasurement",
      "url": "https://github.com/google/GoogleAppMeasurement.git",
      "version": "11.15.0",
      "branch": null,
      "revision": "45ce435e9406d3c674dd249a042b932bee006f60"
    },
    {
      "name": "googledatatransport",
      "url": "https://github.com/google/GoogleDataTransport.git",
      "version": "10.1.0",
      "branch": null,
      "revision": "617af071af9aa1d6a091d59a202910ac482128f9"
    },
    {
      "name": "googleutilities",
      "url": "https://github.com/google/GoogleUtilities.git",
      "version": "8.1.0",
      "branch": null,
      "revision": "60da361632d0de02786f709bdc0c4df340f7613e"
    },
    {
      "name": "grpc-binary",
      "url": "https://github.com/google/grpc-binary.git",
      "version": "1.69.1",
      "branch": null,
      "revision": "75b31c842f664a0f46a2e590a570e370249fd8f6"
    },
    {
      "name": "gtm-session-fetcher",
      "url": "https://github.com/google/gtm-session-fetcher.git",
      "version": "4.5.0",
      "branch": null,
      "revision": "c756a29784521063b6a1202907e2cc47f41b667c"
    },
    {
      "name": "interop-ios-for-google-sdks",
      "url": "https://github.com/google/interop-ios-for-google-sdks.git",
      "version": "101.0.0",
      "branch": null,
      "revision": "040d087ac2267d2ddd4cca36c757d1c6a05fdbfe"
    },
    {
      "name": "kituracontracts",
      "url": "https://github.com/Kitura/KituraContracts.git",
      "version": "2.0.1",
      "branch": null,
      "revision": "6edf7ac3dd2b3a2c61284778d430bbad7d8a6f23"
    },
    {
      "name": "leveldb",
      "url": "https://github.com/firebase/leveldb.git",
      "version": "1.22.5",
      "branch": null,
      "revision": "a0bc79961d7be727d258d33d5a6b2f1023270ba1"
    },
    {
      "name": "loggerapi",
      "url": "https://github.com/Kitura/LoggerAPI.git",
      "version": "2.0.0",
      "branch": null,
      "revision": "4e6b45e850ffa275e8e26a24c6454fd709d5b6ac"
    },
    {
      "name": "mkringprogressview",
      "url": "https://github.com/maxkonovalov/MKRingProgressView.git",
      "version": null,
      "branch": "master",
      "revision": "660888aab1d2ab0ed7eb9eb53caec12af4955fa7"
    },
    {
      "name": "nanopb",
      "url": "https://github.com/firebase/nanopb.git",
      "version": "2.30910.0",
      "branch": null,
      "revision": "b7e1104502eca3a213b46303391ca4d3bc8ddec1"
    },
    {
      "name": "promises",
      "url": "https://github.com/google/promises.git",
      "version": "2.4.0",
      "branch": null,
      "revision": "540318ecedd63d883069ae7f1ed811a2df00b6ac"
    },
    {
      "name": "slidebutton",
      "url": "https://github.com/no-comment/SlideButton",
      "version": null,
      "branch": "main",
      "revision": "5eacebba4d7deeb693592bc9a62ab2d2181e133b"
    },
    {
      "name": "swift-algorithms",
      "url": "https://github.com/apple/swift-algorithms",
      "version": "0.2.1",
      "branch": null,
      "revision": "2327673b0e9c7e90e6b1826376526ec3627210e4"
    },
    {
      "name": "swift-jwt",
      "url": "http://github.com/Kitura/Swift-JWT.git",
      "version": "4.0.1",
      "branch": null,
      "revision": "f68ec28fbd90a651597e9e825ea7f315f8d52a1f"
    },
    {
      "name": "swift-log",
      "url": "https://github.com/apple/swift-log.git",
      "version": "1.10.1",
      "branch": null,
      "revision": "bbd81b6725ae874c69e9b8c8804d462356b55523"
    },
    {
      "name": "swift-numerics",
      "url": "https://github.com/apple/swift-numerics",
      "version": "0.1.0",
      "branch": null,
      "revision": "6583ac70c326c3ee080c1d42d9ca3361dca816cd"
    },
    {
      "name": "swift-protobuf",
      "url": "https://github.com/apple/swift-protobuf.git",
      "version": "1.36.1",
      "branch": null,
      "revision": "a008af1a102ff3dd6cc3764bb69bf63226d0f5f6"
    },
    {
      "name": "swiftcharts",
      "url": "https://github.com/ivanschuetz/SwiftCharts.git",
      "version": null,
      "branch": "master",
      "revision": "c354c1945bb35a1f01b665b22474f6db28cba4a2"
    },
    {
      "name": "swiftdate",
      "url": "https://github.com/malcommac/SwiftDate",
      "version": "6.3.1",
      "branch": null,
      "revision": "6190d0cefff3013e77ed567e6b074f324e5c5bf5"
    },
    {
      "name": "swinject",
      "url": "https://github.com/Swinject/Swinject",
      "version": "2.10.0",
      "branch": null,
      "revision": "b685b549fe4d8ae265fc7a2f27d0789720425d69"
    },
    {
      "name": "tidepoolkit",
      "url": "https://github.com/tidepool-org/TidepoolKit",
      "version": null,
      "branch": "dev",
      "revision": "5c92b4ffc29cabf07609b367e3f82d0f733a6bc1"
    }
  ],
  "build_tools": [
    {
      "name": "SwiftFormat",
      "url": "https://github.com/nicklockwood/SwiftFormat",
      "version": "0.47.11",
      "branch": null,
      "revision": "d1c8a16cc21a3dfc577fe5e881509501ed22d0ce"
    }
  ]
}
```
