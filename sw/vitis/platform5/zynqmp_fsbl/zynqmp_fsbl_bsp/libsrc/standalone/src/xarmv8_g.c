#include "xarmv8.h"

XARMv8_Config XARMv8_ConfigTable[] __attribute__ ((section (".drvcfg_sec"))) = {
	{
		0x5f5e100,  /* stamp-frequency */
		0x47868c00,  /* cpu-frequency */
		0x0  /* reg */
	}
};