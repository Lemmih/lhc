#include "common.h"
#include "objects.h"
#include "nursery.h"
#include "semispace.h"
#include "header.h"
#include "stats.h"
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <assert.h>

#define TEST(name, code) \
  /*printf("%s\n", name);*/ code


int main(void) {
  Stats s;
  Nursery ns;
  SemiSpace semi;

  stats_init(&s);
  { // Header must be exactly one word.
    Header h;
    assert(sizeof(h)==sizeof(word));
  }

  TEST("Number of tags = InfoTable entries", {
    assert(sizeof(InfoTable)/sizeof(ObjectInfo) == TAG_MAX);
  });

  {
    assert(InfoTable[Leaf].ptrs == 0);
    assert(InfoTable[Leaf].prims == 1);
    assert(InfoTable[Branch].ptrs == 2);
  }

  { // Can initialize new nursery.
    nursery_init(&ns);
  }

  { // Allocate/Read round-trip.
    hp leaf;
    nursery_init(&ns);

    leaf = allocate(&ns, NULL, Leaf, (MkLeaf){10});
    assert(readHeader(leaf).data.tag == Leaf);
    assert(((MkLeaf*)readObject(leaf))->n == 10);
  }

  { // Allocation must fail eventually.
    int i;
    nursery_init(&ns);

    for(i=0;i<NURSERY_SIZE*2;i++) {
      hp leaf = allocate(&ns, NULL, Unit, (MkUnit){});
      if(!leaf)
        break;
    }
    assert(i==NURSERY_SIZE);
  }

  { // No early allocation failure.
    nursery_init(&ns);

    for(int i=0;i<NURSERY_SIZE/2;i++) {
      hp leaf = allocate(&ns, NULL, Unit, (MkUnit){});
      assert(leaf);
    }
  }

  { // Nursery evacuation
    hp leaf;
    nursery_init(&ns);
    semi_init(&semi);

    leaf = allocate(&ns, &semi, Leaf, (MkLeaf){10});
    assert(leaf != NULL);
    assert(readHeader(leaf).data.gen == 0); // 0 => nursery

    stats_timer_begin(&s, Gen0Timer);
    nursery_evacuate(&ns, &semi, &leaf);
    nursery_reset(&ns, &semi, &s);

    assert(readHeader(leaf).data.gen == 1);
    assert(!nursery_member(&ns, leaf));
    semi_close(&semi, &s);
  }

  { // Shared object evacuation
    hp leaf, branch;
    nursery_init(&ns);
    semi_init(&semi);

    leaf = allocate(&ns, &semi, Leaf, (MkLeaf){10});
    branch = allocate(&ns, &semi, Branch, (MkBranch){leaf,leaf});

    nursery_evacuate(&ns, &semi, &branch);
    // Check that the leaf object in nursery points forward.
    assert(readHeader(leaf).data.isForwardPtr == 1);
    // Update leaf reference and check that the new object isn't a forwarding
    // pointer.
    nursery_evacuate(&ns, &semi, &leaf);
    assert(readHeader(leaf).data.isForwardPtr == 0);

    // Check that the leaf node hasn't been duplicated.
    assert(((MkBranch*)readObject(branch))->left == ((MkBranch*)readObject(branch))->right);

    semi_close(&semi, &s);
  }

  { // SemiSpace GC check
    hp leaf;
    nursery_init(&ns);
    semi_init(&semi);

    leaf = allocate(&ns, &semi, Leaf, (MkLeaf){10});
    assert(readHeader(leaf).data.gen == 0);

    nursery_evacuate(&ns, &semi, &leaf);
    assert(readHeader(leaf).data.gen == 1);
    assert(readHeader(leaf).data.grey == 0);
    assert(readHeader(leaf).data.black == semi.black_bit);
    assert(semi_size(&semi) == 2);

    semi_scavenge(&semi, &s);
    assert(readHeader(leaf).data.gen == 1);
    assert(readHeader(leaf).data.grey == 0);
    assert(readHeader(leaf).data.black == !semi.black_bit);
    assert(semi_size(&semi) == 2);

    semi_evacuate(&semi, &leaf);
    assert(readHeader(leaf).data.gen == 1);
    assert(readHeader(leaf).data.grey == 1);
    assert(readHeader(leaf).data.black == !semi.black_bit);
    assert(semi_size(&semi) == 4);

    semi_scavenge(&semi, &s);
    assert(readHeader(leaf).data.gen == 1);
    assert(readHeader(leaf).data.grey == 0);
    assert(readHeader(leaf).data.black == !semi.black_bit);
    assert(semi_size(&semi) == 2);

    semi_close(&semi, &s);
  }

  {
    hp leaf, prevAddr;
    nursery_init(&ns);
    semi_init(&semi);

    nursery_bypass(&ns, &semi);

    leaf = allocate(&ns, &semi, Leaf, (MkLeaf){10});
    prevAddr = leaf;
    assert(readHeader(leaf).data.gen == 0);

    nursery_evacuate(&ns, &semi, &leaf);
    assert(readHeader(leaf).data.gen == 1);
    assert(readHeader(leaf).data.grey == 0);
    assert(readHeader(leaf).data.black == semi.black_bit);
    assert(leaf == prevAddr);

    semi_close(&semi, &s);
  }

  printf("All OK.\n");
  return 0;
}
