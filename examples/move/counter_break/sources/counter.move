// A compatibility-breaking variant of examples::counter.
// The canonical module exposes reset(); this fixture removes it so package
// upgrade compatibility checks have a stable negative case.
module examples::counter {
    use setu::object::{Self, UID};
    use setu::transfer;
    use setu::tx_context::{Self, TxContext};

    struct Counter has key, store {
        id: UID,
        value: u64,
        owner: address,
    }

    public entry fun create(ctx: &mut TxContext) {
        let counter = Counter {
            id: object::new(ctx),
            value: 0,
            owner: tx_context::sender(ctx),
        };
        transfer::transfer(counter, tx_context::sender(ctx));
    }

    public entry fun increment(counter: &mut Counter) {
        counter.value = counter.value + 1;
    }

    public entry fun increment_by(counter: &mut Counter, amount: u64) {
        counter.value = counter.value + amount;
    }

    public fun value(counter: &Counter): u64 {
        counter.value
    }

    public entry fun transfer_to(counter: Counter, recipient: address) {
        transfer::transfer(counter, recipient);
    }
}
