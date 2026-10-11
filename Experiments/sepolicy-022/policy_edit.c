/*
 * policy_edit: add or query one allow rule in a compiled (binary) SELinux policy.
 *
 * Test-only tool for the #022 experiment (see the implementation review IR-940 to IR-959).
 * It is linked against the pinned libsepol 3.11 (ThirdParty/ThirdParty.lock.json, libsepol).
 * It never sets a permissive mode, and it does not check neverallow rules, because the
 * compiled policy does not carry them.
 *
 * Usage:
 *   policy_edit roundtrip <in> <out>
 *       Read and write the policy without a change.
 *   policy_edit add <in> <out> <source-type> <target-type> <class> <perm>
 *       Write <out> with "allow <source> <target>:<class> { <perm> };" added (ORed into an
 *       existing allow entry for the same key when one exists).
 *   policy_edit query <in> <source-type> <target-type> <class> <perm>
 *       Print ALLOWED or DENIED for the allow rule. Exit 0 when allowed, 1 when not.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sepol/handle.h>
#include <sepol/policydb/avtab.h>
#include <sepol/policydb/hashtab.h>
#include <sepol/policydb/policydb.h>

static void die(const char *message, const char *detail)
{
	fprintf(stderr, "policy_edit: %s%s%s\n", message, detail ? ": " : "", detail ? detail : "");
	exit(2);
}

static policydb_t *load_policy(sepol_handle_t *handle, const char *path)
{
	FILE *fp = fopen(path, "rb");
	policy_file_t pf;
	policydb_t *p = calloc(1, sizeof(*p));

	if (!fp)
		die("cannot open the input policy", path);
	if (!p)
		die("out of memory", NULL);
	policy_file_init(&pf);
	pf.type = PF_USE_STDIO;
	pf.fp = fp;
	pf.handle = handle;
	if (policydb_init(p))
		die("policydb_init failed", NULL);
	if (policydb_read(p, &pf, 0))
		die("policydb_read failed (not a binary policy?)", path);
	fclose(fp);
	return p;
}

/* The policy header's config word (file offset 20). libsepol reads only bits 0 to 2 of it, and
 * its writer keeps only those bits, so bits 30 and 31 (0xc0000000 in the stock /sepolicy) would
 * be lost. The kernel reads the same three bits, so the loss would not change the policy, but the
 * tool writes the input's word back so that the only difference is the rule. */
#define CONFIG_OFFSET 20

static uint32_t read_config_word(const char *path)
{
	FILE *fp = fopen(path, "rb");
	unsigned char b[4];

	if (!fp || fseek(fp, CONFIG_OFFSET, SEEK_SET) || fread(b, 1, 4, fp) != 4)
		die("cannot read the policy config word", path);
	fclose(fp);
	return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
	       ((uint32_t)b[3] << 24);
}

static void save_policy(sepol_handle_t *handle, policydb_t *p, const char *path,
			const char *source_path)
{
	FILE *fp;
	policy_file_t pf;
	uint32_t original, written;
	unsigned char b[4];

	/* Read the input's word first: the output may be the input file, and opening it truncates it. */
	original = read_config_word(source_path);
	fp = fopen(path, "wb");
	if (!fp)
		die("cannot open the output policy", path);
	policy_file_init(&pf);
	pf.type = PF_USE_STDIO;
	pf.fp = fp;
	pf.handle = handle;
	if (policydb_write(p, &pf))
		die("policydb_write failed", path);
	if (fclose(fp))
		die("cannot close the output policy", path);

	fp = fopen(path, "r+b");
	if (!fp || fseek(fp, CONFIG_OFFSET, SEEK_SET) || fread(b, 1, 4, fp) != 4)
		die("cannot reopen the output policy", path);
	written = (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) |
		  ((uint32_t)b[3] << 24);
	if ((written & 7) != (original & 7))
		die("the libsepol bits of the config word differ from the input", path);
	if (written != original) {
		b[0] = original & 0xff;
		b[1] = (original >> 8) & 0xff;
		b[2] = (original >> 16) & 0xff;
		b[3] = (original >> 24) & 0xff;
		if (fseek(fp, CONFIG_OFFSET, SEEK_SET) || fwrite(b, 1, 4, fp) != 4)
			die("cannot restore the config word", path);
		printf("config word 0x%08x kept from the input (libsepol wrote 0x%08x)\n", original,
		       written);
	}
	if (fclose(fp))
		die("cannot close the output policy", path);
}

/* Print every allow-type rule (the avtab) by name, and the symbol counts and header fields. Conditional
 * rules (te_cond_avtab) are not printed; the policies of this experiment have no booleans, so they have none. */
static void dump_policy(policydb_t *p)
{
	uint32_t bucket;
	int i;

	printf("policyvers %u mls %u handle_unknown %u\n", p->policyvers, p->mls,
	       p->handle_unknown);
	for (i = 0; i < SYM_NUM; i++)
		printf("symbols %d %u\n", i, p->symtab[i].nprim);
	for (bucket = 0; bucket < p->te_avtab.nslot; bucket++) {
		avtab_ptr_t node;

		for (node = p->te_avtab.htable[bucket]; node; node = node->next) {
			printf("avtab %s %s %s 0x%04x 0x%08x\n",
			       p->p_type_val_to_name[node->key.source_type - 1],
			       p->p_type_val_to_name[node->key.target_type - 1],
			       p->p_class_val_to_name[node->key.target_class - 1],
			       (unsigned)node->key.specified, node->datum.data);
		}
	}
}

static uint32_t type_value(policydb_t *p, const char *name)
{
	type_datum_t *type = hashtab_search(p->symtab[SYM_TYPES].table, name);

	if (!type)
		die("no such type in the policy", name);
	if (type->flavor != TYPE_TYPE)
		die("the name is an attribute or an alias, not a plain type", name);
	return type->s.value;
}

static class_datum_t *class_of(policydb_t *p, const char *name)
{
	class_datum_t *cls = hashtab_search(p->symtab[SYM_CLASSES].table, name);

	if (!cls)
		die("no such object class in the policy", name);
	return cls;
}

static uint32_t permission_bit(class_datum_t *cls, const char *perm)
{
	perm_datum_t *datum = hashtab_search(cls->permissions.table, perm);

	if (!datum && cls->comdatum)
		datum = hashtab_search(cls->comdatum->permissions.table, perm);
	if (!datum)
		die("no such permission for the class", perm);
	if (datum->s.value < 1 || datum->s.value > 32)
		die("permission value out of range", perm);
	return UINT32_C(1) << (datum->s.value - 1);
}

static avtab_key_t allow_key(policydb_t *p, const char *source, const char *target,
			     const char *cls)
{
	avtab_key_t key;

	memset(&key, 0, sizeof(key));
	key.source_type = (uint16_t)type_value(p, source);
	key.target_type = (uint16_t)type_value(p, target);
	key.target_class = (uint16_t)class_of(p, cls)->s.value;
	key.specified = AVTAB_ALLOWED;
	return key;
}

int main(int argc, char **argv)
{
	sepol_handle_t *handle = sepol_handle_create();
	policydb_t *p;

	if (!handle)
		die("out of memory", NULL);
	if (argc >= 4 && strcmp(argv[1], "roundtrip") == 0) {
		p = load_policy(handle, argv[2]);
		printf("policyvers %u avtab-entries %u\n", p->policyvers, p->te_avtab.nel);
		save_policy(handle, p, argv[3], argv[2]);
		return 0;
	}
	if (argc == 8 && strcmp(argv[1], "add") == 0) {
		avtab_key_t key;
		avtab_datum_t *existing;
		avtab_datum_t fresh;
		uint32_t bit, before;
		uint32_t entries_before;

		p = load_policy(handle, argv[2]);
		entries_before = p->te_avtab.nel;
		key = allow_key(p, argv[4], argv[5], argv[6]);
		bit = permission_bit(class_of(p, argv[6]), argv[7]);
		existing = avtab_search(&p->te_avtab, &key);
		if (existing) {
			before = existing->data;
			existing->data |= bit;
		} else {
			before = 0;
			memset(&fresh, 0, sizeof(fresh));
			fresh.data = bit;
			if (avtab_insert(&p->te_avtab, &key, &fresh))
				die("avtab_insert failed", NULL);
		}
		printf("added allow %s %s:%s { %s } mask 0x%08x -> 0x%08x (avtab entries %u -> %u)\n",
		       argv[4], argv[5], argv[6], argv[7], before, before | bit, entries_before,
		       p->te_avtab.nel);
		save_policy(handle, p, argv[3], argv[2]);
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "dump") == 0) {
		p = load_policy(handle, argv[2]);
		dump_policy(p);
		return 0;
	}
	if (argc == 7 && strcmp(argv[1], "query") == 0) {
		avtab_datum_t *datum;
		avtab_key_t key;
		uint32_t bit;
		int allowed;

		p = load_policy(handle, argv[2]);
		key = allow_key(p, argv[3], argv[4], argv[5]);
		bit = permission_bit(class_of(p, argv[5]), argv[6]);
		datum = avtab_search(&p->te_avtab, &key);
		allowed = datum && (datum->data & bit);
		printf("%s allow %s %s:%s { %s }\n", allowed ? "ALLOWED" : "DENIED", argv[3],
		       argv[4], argv[5], argv[6]);
		return allowed ? 0 : 1;
	}
	fprintf(stderr, "usage: policy_edit roundtrip <in> <out> | dump <in> | add <in> <out> "
			"<src> <tgt> <class> <perm> | query <in> <src> <tgt> <class> <perm>\n");
	return 2;
}
