import BitcoinCore
import HSHDWalletKit
import BigInt
import HSCryptoKit
import RxSwift

public class DashKit: AbstractKit {
    private static let heightInterval = 24                                      // Blocks count in window for calculating difficulty
    private static let targetSpacing = 150                                      // Time to mining one block ( 2.5 min. Dash )
    private static let maxTargetBits = 0x1e0fffff                               // Initially and max. target difficulty for blocks ( Dash )

    public static func clear() throws {
        try DirectoryHelper.removeDirectory("DashKit")
    }

    public enum NetworkType { case mainNet, testNet }

    weak public var delegate: DashKitDelegate?

    private let storage: IDashStorage

    private var masternodeSyncer: MasternodeListSyncer?
    private let dashTransactionInfoConverter: ITransactionInfoConverter

    public init(withWords words: [String], walletId: String, newWallet: Bool = false, networkType: NetworkType = .mainNet, confirmationsThreshold: Int = 6, minLogLevel: Logger.Level = .verbose) throws {
        let network: INetwork
        var initialSyncApiUrl: String

        switch networkType {
        case .mainNet:
            network = MainNet()
            initialSyncApiUrl = "https://dash.horizontalsystems.xyz/apg"
        case .testNet:
            network = TestNet()
            initialSyncApiUrl = "http://dash-testnet.horizontalsystems.xyz/apg"
        }
        let initialSyncApi = InsightApi(url: initialSyncApiUrl)

        let logger = Logger(network: network, minLogLevel: minLogLevel)

        let databaseFilePath = try DirectoryHelper.directoryURL(for: "DashKit").appendingPathComponent("\(walletId)-\(networkType)").path
        let storage = DashGrdbStorage(databaseFilePath: databaseFilePath)
        self.storage = storage

        let paymentAddressParser = PaymentAddressParser(validScheme: "dash", removeScheme: true)
        let addressSelector = DashAddressSelector()

        let singleHasher = SingleHasher()   // Use single sha256 for hash
        let doubleShaHasher = DoubleShaHasher()     // Use doubleSha256 for hash
        let x11Hasher = X11Hasher()         // Use for block header hash

        let instantSendFactory = InstantSendFactory()
        let instantTransactionState = InstantTransactionState()
        let instantTransactionManager = InstantTransactionManager(storage: storage, instantSendFactory: instantSendFactory, instantTransactionState: instantTransactionState)

        dashTransactionInfoConverter = DashTransactionInfoConverter(baseTransactionInfoConverter: BaseTransactionInfoConverter(), instantTransactionManager: instantTransactionManager)

        let bitcoinCore = try BitcoinCoreBuilder(minLogLevel: minLogLevel)
                .set(network: network)
                .set(words: words)
                .set(initialSyncApi: initialSyncApi)
                .set(paymentAddressParser: paymentAddressParser)
                .set(addressSelector: addressSelector)
                .set(walletId: walletId)
                .set(peerSize: 4)
                .set(storage: storage)
                .set(newWallet: newWallet)
                .set(blockHeaderHasher: x11Hasher)
                .set(transactionInfoConverter: dashTransactionInfoConverter)
                .build()

        super.init(bitcoinCore: bitcoinCore, network: network)
        bitcoinCore.delegate = self

        // extending BitcoinCore

        let masternodeParser = MasternodeParser(hasher: singleHasher)

        bitcoinCore.add(messageParser: TransactionLockMessageParser())
                .add(messageParser: TransactionLockVoteMessageParser())
                .add(messageParser: MasternodeListDiffMessageParser(masternodeParser: masternodeParser))
                .add(messageParser: ISLockParser(hasher: doubleShaHasher))

        bitcoinCore.add(messageSerializer: GetMasternodeListDiffMessageSerializer())

        let blockHelper = BlockValidatorHelper(storage: storage)
        let difficultyEncoder = DifficultyEncoder()

        let targetTimespan = DashKit.heightInterval * DashKit.targetSpacing                 // Time to mining all 24 blocks in circle
        switch networkType {
        case .mainNet:
            bitcoinCore.add(blockValidator: DarkGravityWaveValidator(encoder: difficultyEncoder, blockHelper: blockHelper, heightInterval: DashKit.heightInterval , targetTimeSpan: targetTimespan, maxTargetBits: DashKit.maxTargetBits, firstCheckpointHeight: network.checkpointBlock.height))
        case .testNet:
            bitcoinCore.add(blockValidator: DarkGravityWaveTestNetValidator(difficultyEncoder: difficultyEncoder, targetSpacing: DashKit.targetSpacing, targetTimeSpan: targetTimespan, maxTargetBits: DashKit.maxTargetBits))
            bitcoinCore.add(blockValidator: DarkGravityWaveValidator(encoder: difficultyEncoder, blockHelper: blockHelper, heightInterval: DashKit.heightInterval, targetTimeSpan: targetTimespan, maxTargetBits: DashKit.maxTargetBits, firstCheckpointHeight: network.checkpointBlock.height))
        }

        let merkleBranch = MerkleBranch(hasher: doubleShaHasher)

        let masternodeSerializer = MasternodeSerializer()
        let coinbaseTransactionSerializer = CoinbaseTransactionSerializer()
        let masternodeCbTxHasher = MasternodeCbTxHasher(coinbaseTransactionSerializer: coinbaseTransactionSerializer, hasher: doubleShaHasher)
        let masternodeMerkleRootCreator = MerkleRootCreator(hasher: doubleShaHasher)

        let masternodeListMerkleRootCalculator = MasternodeListMerkleRootCalculator(masternodeSerializer: masternodeSerializer, masternodeHasher: doubleShaHasher, masternodeMerkleRootCreator: masternodeMerkleRootCreator)
        let masternodeListManager = MasternodeListManager(storage: storage, masternodeListMerkleRootCalculator: masternodeListMerkleRootCalculator, masternodeCbTxHasher: masternodeCbTxHasher, merkleBranch: merkleBranch)
        let masternodeSyncer = MasternodeListSyncer(bitcoinCore: bitcoinCore, initialBlockDownload: bitcoinCore.initialBlockDownload, peerTaskFactory: PeerTaskFactory(), masternodeListManager: masternodeListManager)

        bitcoinCore.add(peerTaskHandler: masternodeSyncer)

        masternodeSyncer.subscribeTo(observable: bitcoinCore.initialBlockDownload.observable)
        masternodeSyncer.subscribeTo(observable: bitcoinCore.peerGroup.observable)

        self.masternodeSyncer = masternodeSyncer

        let calculator = TransactionSizeCalculator()
        let confirmedUnspentOutputProvider = ConfirmedUnspentOutputProvider(storage: storage, confirmationsThreshold: confirmationsThreshold)
        bitcoinCore.prepend(unspentOutputSelector: UnspentOutputSelector(calculator: calculator, provider: confirmedUnspentOutputProvider, outputsLimit: 4))
        bitcoinCore.prepend(unspentOutputSelector: UnspentOutputSelectorSingleNoChange(calculator: calculator, provider: confirmedUnspentOutputProvider))
// --------------------------------------
        let transactionLockVoteValidator = TransactionLockVoteValidator(storage: storage, hasher: singleHasher)
        let instantSendLockValidator = InstantSendLockValidator()
        let instantTransactionSyncer = InstantTransactionSyncer(transactionSyncer: bitcoinCore.transactionSyncer)
        let lockVoteManager = TransactionLockVoteManager(transactionLockVoteValidator: transactionLockVoteValidator)

        let instantSend = InstantSend(transactionSyncer: instantTransactionSyncer, lockVoteManager: lockVoteManager, instantSendLockValidator: instantSendLockValidator, instantTransactionManager: instantTransactionManager, logger: logger)
        instantSend.delegate = self

        bitcoinCore.add(peerTaskHandler: instantSend)
        bitcoinCore.add(inventoryItemsHandler: instantSend)
// --------------------------------------

    }

    private func cast(transactionInfos:[TransactionInfo]) -> [DashTransactionInfo] {
        return transactionInfos.compactMap { $0 as? DashTransactionInfo }
    }

    public override func send(to address: String, value: Int, feeRate: Int) throws {
        try super.send(to: address, value: value, feeRate: feeRate)
    }

    public func transactions(fromHash: String?, limit: Int?) -> Single<[DashTransactionInfo]> {
        return super.transactions(fromHash: fromHash, limit: limit).map { self.cast(transactionInfos: $0) }
    }

}

extension DashKit: BitcoinCoreDelegate {

    public func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        delegate?.transactionsUpdated(inserted: cast(transactionInfos: inserted), updated: cast(transactionInfos: updated))
    }

    public func transactionsDeleted(hashes: [String]) {
        delegate?.transactionsDeleted(hashes: hashes)
    }

    public func balanceUpdated(balance: Int) {
        delegate?.balanceUpdated(balance: balance)
    }

    public func lastBlockInfoUpdated(lastBlockInfo: BlockInfo) {
        delegate?.lastBlockInfoUpdated(lastBlockInfo: lastBlockInfo)
    }

    public func kitStateUpdated(state: BitcoinCore.KitState) {
        delegate?.kitStateUpdated(state: state)
    }

}

extension DashKit: IInstantTransactionDelegate {

    public func onUpdateInstant(transactionHash: Data) {
        guard let transaction = storage.fullTransactionInfo(byHash: transactionHash) else {
            return
        }
        let transactionInfo = dashTransactionInfoConverter.transactionInfo(fromTransaction: transaction)
        bitcoinCore.delegateQueue.async { [weak self] in
            if let kit = self {
                kit.delegate?.transactionsUpdated(inserted: [], updated: kit.cast(transactionInfos: [transactionInfo]))
            }
        }
    }

}
