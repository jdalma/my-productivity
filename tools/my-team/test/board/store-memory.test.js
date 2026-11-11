/** The memory adapter against the store contract (T63a). */

import { runStoreContract } from './store-contract.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';

runStoreContract('memory', () => createMemoryStore());
