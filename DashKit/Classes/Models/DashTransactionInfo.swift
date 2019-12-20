import BitcoinCore

public class DashTransactionInfo: TransactionInfo {
    public var instantTx: Bool = false

    private enum CodingKeys: String, CodingKey {
        case instantTx
    }

    public required init(uid: String, transactionHash: String, transactionIndex: Int, inputs: [TransactionInputInfo], outputs: [TransactionOutputInfo], fee: Int?, blockHeight: Int?, timestamp: Int, status: TransactionStatus) {
        super.init(uid: uid, transactionHash: transactionHash, transactionIndex: transactionIndex, inputs: inputs, outputs: outputs, fee: fee, blockHeight: blockHeight, timestamp: timestamp, status: status)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)

        let container = try decoder.container(keyedBy: CodingKeys.self)
        instantTx = try container.decode(Bool.self, forKey: .instantTx)
    }

    override public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(instantTx, forKey: .instantTx)

        try super.encode(to: encoder)
    }

}