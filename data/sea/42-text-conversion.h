#include "41-grisu2.h"

/*
utils
*/

static bool INLINE text_is_digit (char c)
{
    return c >= '0' && c <= '9';
}

/*
iint_t read/write
*/

static const size_t text_iint_max_size = 20; /* 64-bit integer = 19 digits + sign */

static ierror_loc_t INLINE text_read_iint (char **pp, char *pe, iint_t *output_ptr)
{
    char  *p           = *pp;
    size_t buffer_size = pe - p;

    /* handle negative */
    int sign      = 1;
    int sign_size = 0;
    if (buffer_size > 0 && p[0] == '-') {
        sign      = -1;
        sign_size = 1;
        p++;
        buffer_size--;
    }

    /* validate digits */
    size_t digits = 0;
    while (digits < buffer_size) {
        if (!text_is_digit (p[digits]))
            break;
        digits++;
    }

    if (digits == 0)
        return ierror_loc_format (*pp, *pp, "not an integer");

    iint_t value = 0;

    /* handle up to 19 digits, assume we're 64-bit */
    switch (digits) {
        case 19:  value += (p[digits-19] - '0') * 1000000000000000000LL;
        case 18:  value += (p[digits-18] - '0') * 100000000000000000LL;
        case 17:  value += (p[digits-17] - '0') * 10000000000000000LL;
        case 16:  value += (p[digits-16] - '0') * 1000000000000000LL;
        case 15:  value += (p[digits-15] - '0') * 100000000000000LL;
        case 14:  value += (p[digits-14] - '0') * 10000000000000LL;
        case 13:  value += (p[digits-13] - '0') * 1000000000000LL;
        case 12:  value += (p[digits-12] - '0') * 100000000000LL;
        case 11:  value += (p[digits-11] - '0') * 10000000000LL;
        case 10:  value += (p[digits-10] - '0') * 1000000000LL;
        case  9:  value += (p[digits- 9] - '0') * 100000000LL;
        case  8:  value += (p[digits- 8] - '0') * 10000000LL;
        case  7:  value += (p[digits- 7] - '0') * 1000000LL;
        case  6:  value += (p[digits- 6] - '0') * 100000LL;
        case  5:  value += (p[digits- 5] - '0') * 10000LL;
        case  4:  value += (p[digits- 4] - '0') * 1000LL;
        case  3:  value += (p[digits- 3] - '0') * 100LL;
        case  2:  value += (p[digits- 2] - '0') * 10LL;
        case  1:  value += (p[digits- 1] - '0');
        /* ^ fall through */
            value *= sign;
            *output_ptr = value;
            *pp += digits + sign_size;
            return 0;

        default:
            return ierror_loc_format (*pp + digits + sign_size - 1, *pp, "integer too big, only 64-bits supported");
    }
}

static ierror_loc_t INLINE json_read_iint (char **pp, char *pe, iint_t *output_ptr)
{
    return text_read_iint (pp, pe, output_ptr);
}

static size_t INLINE text_write_iint (iint_t value, char *p)
{
    return snprintf (p, text_iint_max_size, "%lld", value);
}


/*
idouble_t read/write
*/

static const size_t text_idouble_max_size = 32;

static ierror_loc_t INLINE text_read_uint64 (char **pp, char *pe, uint64_t *output_ptr)
{
    char  *p           = *pp;
    size_t buffer_size = pe - p;

    /* validate digits */
    size_t digits = 0;
    while (digits < buffer_size) {
        if (!text_is_digit (p[digits]))
            break;
        digits++;
    }

    if (digits == 0)
        return ierror_loc_format ("not a number", *pp, *pp);

    iint_t value = 0;

    /* handle up to 19 digits, we can fit up to 64-bit */
    switch (digits) {
        case 19:  value += (p[digits-19] - '0') * 1000000000000000000LL;
        case 18:  value += (p[digits-18] - '0') * 100000000000000000LL;
        case 17:  value += (p[digits-17] - '0') * 10000000000000000LL;
        case 16:  value += (p[digits-16] - '0') * 1000000000000000LL;
        case 15:  value += (p[digits-15] - '0') * 100000000000000LL;
        case 14:  value += (p[digits-14] - '0') * 10000000000000LL;
        case 13:  value += (p[digits-13] - '0') * 1000000000000LL;
        case 12:  value += (p[digits-12] - '0') * 100000000000LL;
        case 11:  value += (p[digits-11] - '0') * 10000000000LL;
        case 10:  value += (p[digits-10] - '0') * 1000000000LL;
        case  9:  value += (p[digits- 9] - '0') * 100000000LL;
        case  8:  value += (p[digits- 8] - '0') * 10000000LL;
        case  7:  value += (p[digits- 7] - '0') * 1000000LL;
        case  6:  value += (p[digits- 6] - '0') * 100000LL;
        case  5:  value += (p[digits- 5] - '0') * 10000LL;
        case  4:  value += (p[digits- 4] - '0') * 1000LL;
        case  3:  value += (p[digits- 3] - '0') * 100LL;
        case  2:  value += (p[digits- 2] - '0') * 10LL;
        case  1:  value += (p[digits- 1] - '0');
        /* ^ fall through */
            *output_ptr = value;
            *pp += digits;
            return 0;

        default:
            return ierror_loc_format (*pp + digits - 1, *pp, "number too big");
    }
}

static double INLINE unsafe_dpow10(int n)
{
    static const double e[] = {
        1e+0,
        1e+1,  1e+2,  1e+3,  1e+4,  1e+5,  1e+6,  1e+7,  1e+8,  1e+9,  1e+10,
        1e+11, 1e+12, 1e+13, 1e+14, 1e+15, 1e+16, 1e+17, 1e+18, 1e+19, 1e+20,
        1e+21, 1e+22, 1e+23, 1e+24, 1e+25, 1e+26, 1e+27, 1e+28, 1e+29, 1e+30,
        1e+31, 1e+32, 1e+33, 1e+34, 1e+35, 1e+36, 1e+37, 1e+38, 1e+39, 1e+40,
        1e+41, 1e+42, 1e+43, 1e+44, 1e+45, 1e+46, 1e+47, 1e+48, 1e+49, 1e+50,
        1e+51, 1e+52, 1e+53, 1e+54, 1e+55, 1e+56, 1e+57, 1e+58, 1e+59, 1e+60,
        1e+61, 1e+62, 1e+63, 1e+64, 1e+65, 1e+66, 1e+67, 1e+68, 1e+69, 1e+70,
        1e+71, 1e+72, 1e+73, 1e+74, 1e+75, 1e+76, 1e+77, 1e+78, 1e+79, 1e+80,
        1e+81, 1e+82, 1e+83, 1e+84, 1e+85, 1e+86, 1e+87, 1e+88, 1e+89, 1e+90,
        1e+91, 1e+92, 1e+93, 1e+94, 1e+95, 1e+96, 1e+97, 1e+98, 1e+99, 1e+100,
        1e+101,1e+102,1e+103,1e+104,1e+105,1e+106,1e+107,1e+108,1e+109,1e+110,
        1e+111,1e+112,1e+113,1e+114,1e+115,1e+116,1e+117,1e+118,1e+119,1e+120,
        1e+121,1e+122,1e+123,1e+124,1e+125,1e+126,1e+127,1e+128,1e+129,1e+130,
        1e+131,1e+132,1e+133,1e+134,1e+135,1e+136,1e+137,1e+138,1e+139,1e+140,
        1e+141,1e+142,1e+143,1e+144,1e+145,1e+146,1e+147,1e+148,1e+149,1e+150,
        1e+151,1e+152,1e+153,1e+154,1e+155,1e+156,1e+157,1e+158,1e+159,1e+160,
        1e+161,1e+162,1e+163,1e+164,1e+165,1e+166,1e+167,1e+168,1e+169,1e+170,
        1e+171,1e+172,1e+173,1e+174,1e+175,1e+176,1e+177,1e+178,1e+179,1e+180,
        1e+181,1e+182,1e+183,1e+184,1e+185,1e+186,1e+187,1e+188,1e+189,1e+190,
        1e+191,1e+192,1e+193,1e+194,1e+195,1e+196,1e+197,1e+198,1e+199,1e+200,
        1e+201,1e+202,1e+203,1e+204,1e+205,1e+206,1e+207,1e+208,1e+209,1e+210,
        1e+211,1e+212,1e+213,1e+214,1e+215,1e+216,1e+217,1e+218,1e+219,1e+220,
        1e+221,1e+222,1e+223,1e+224,1e+225,1e+226,1e+227,1e+228,1e+229,1e+230,
        1e+231,1e+232,1e+233,1e+234,1e+235,1e+236,1e+237,1e+238,1e+239,1e+240,
        1e+241,1e+242,1e+243,1e+244,1e+245,1e+246,1e+247,1e+248,1e+249,1e+250,
        1e+251,1e+252,1e+253,1e+254,1e+255,1e+256,1e+257,1e+258,1e+259,1e+260,
        1e+261,1e+262,1e+263,1e+264,1e+265,1e+266,1e+267,1e+268,1e+269,1e+270,
        1e+271,1e+272,1e+273,1e+274,1e+275,1e+276,1e+277,1e+278,1e+279,1e+280,
        1e+281,1e+282,1e+283,1e+284,1e+285,1e+286,1e+287,1e+288,1e+289,1e+290,
        1e+291,1e+292,1e+293,1e+294,1e+295,1e+296,1e+297,1e+298,1e+299,1e+300,
        1e+301,1e+302,1e+303,1e+304,1e+305,1e+306,1e+307,1e+308
    };
    return e[n];
}

static int64_t INLINE unsafe_ipow10(int n)
{
    static const int64_t e[] = {
        0LL,
        10LL,
        100LL,
        1000LL,
        10000LL,
        100000LL,
        1000000LL,
        10000000LL,
        100000000LL,
        1000000000LL,
        10000000000LL,
        100000000000LL,
        1000000000000LL,
        10000000000000LL,
        100000000000000LL,
        1000000000000000LL,
        10000000000000000LL,
        100000000000000000LL,
        1000000000000000000LL
    };
    return e[n];
}

static double INLINE double_from_parts_fast (double significand, int exponent)
{
    if (exponent < -308)
        return 0.0;
    else if (exponent >= 0)
        return significand * unsafe_dpow10 (exponent);
    else
        return significand / unsafe_dpow10 (-exponent);
}

static double INLINE double_from_parts (double significand, int exponent)
{
    if (exponent < -308) {
        double value;
        value = double_from_parts_fast (significand, -308);
        value = double_from_parts_fast (value, exponent + 308);
        return value;
    } else {
        return double_from_parts_fast (significand, exponent);
    }
}

static ierror_loc_t INLINE text_read_idouble (char **pp, char *pe, idouble_t *output_ptr)
{
    char *p = *pp;

    /* sign part */
    int64_t sign = 1;
    if (pe - p > 0 && p[0] == '-') {
        sign = -1;
        p++;
    }

    static const uint64_t to_lower      = 0x2020202020202020;

    static const size_t   infinity_size = 8;
    static const uint64_t infinity_mask = 0xffffffffffffffff;
    static const uint64_t infinity_bits = 0x7974696e69666e69;

    static const size_t   inf_size      = 3;
    static const uint64_t inf_mask      = 0x0000000000ffffff;
    static const uint64_t inf_bits      = 0x0000000000666e69;

    static const size_t   nan_size      = 3;
    static const uint64_t nan_mask      = 0x0000000000ffffff;
    static const uint64_t nan_bits      = 0x00000000006e616e;

    size_t   size = pe - p;
    uint64_t u64  = *(uint64_t *)p | to_lower;

#define COMPARE_WORD(name,x)                                                    \
    if (name##_size >= size &&                                                  \
        name##_bits == (u64 & name##_mask)) {                                   \
        *pp         = p + name##_size;                                          \
        *output_ptr = sign * x;                                                 \
        return 0;                                                               \
    }

    COMPARE_WORD(infinity, INFINITY);
    COMPARE_WORD(inf,      INFINITY);
    COMPARE_WORD(nan,      NAN);

    uint64_t int_part;
    ierror_loc_t error = text_read_uint64 (&p, pe, &int_part);
    if (error) return error;

    int     exponent    = 0;
    int64_t significand = (int64_t)int_part;

    /* fractional part */
    if (pe - p > 0 && p[0] == '.') {
        p++;

        char *ps = p;

        uint64_t frac_part;
        ierror_loc_t error = text_read_uint64 (&p, pe, &frac_part);
        if (error) return error;

        int digits = p - ps;

        significand = significand * unsafe_ipow10 (digits) + frac_part;
        exponent   -= digits;
    }

    /* exponent part */
    if (pe - p > 1 && (p[0] == 'e' || p[0] == 'E')) {
        p++;

        if (p[0] == '-') {
            p++;

            uint64_t exp_part;
            ierror_loc_t error = text_read_uint64 (&p, pe, &exp_part);
            if (error) return error;

            exponent -= (int64_t)exp_part;
        } else {
            if (p[0] == '+') p++;

            uint64_t exp_part;
            ierror_loc_t error = text_read_uint64 (&p, pe, &exp_part);
            if (error) return error;

            exponent += (int64_t)exp_part;
        }
    }

    *output_ptr = double_from_parts (sign * significand, exponent);
    *pp         = p;

    return 0;
}

static ierror_loc_t INLINE json_read_idouble (char **pp, char *pe, idouble_t *output_ptr)
{
    return text_read_idouble (pp, pe, output_ptr);
}

static size_t INLINE text_write_idouble (idouble_t value, char *p)
{
    return grisu2_double_to_string (value, p);
}


/*
ibool_t read
*/

static ierror_loc_t INLINE mask_read_ibool (uint64_t mask, char **pp, char *pe, ibool_t *output_ptr)
{
    static const uint64_t true_mask  = 0x00000000ffffffff;
    static const uint64_t true_bits  = 0x0000000065757274; /* "true" */
    static const uint64_t false_mask = 0x000000ffffffffff;
    static const uint64_t false_bits = 0x00000065736c6166; /* "false" */

    char *p = *pp;

    uint64_t next8 = *(uint64_t *)p | mask;

    int is_true  = (next8 & true_mask)  == true_bits;
    int is_false = (next8 & false_mask) == false_bits;

    if (is_true) {
        *output_ptr = itrue;
        *pp         = p + sizeof ("true") - 1;
    } else if (is_false) {
        *output_ptr = ifalse;
        *pp         = p + sizeof ("false") - 1;
    } else {
        return ierror_loc_format (p, p, "not a boolean");
    }

    return 0;
}

static ierror_loc_t INLINE text_read_ibool (char **pp, char *pe, ibool_t *output_ptr)
{
    static const uint64_t to_lower = 0x2020202020202020;
    return mask_read_ibool (to_lower, pp, pe, output_ptr);
}

static ierror_loc_t INLINE json_read_ibool (char **pp, char *pe, ibool_t *output_ptr)
{
    return mask_read_ibool (0x0, pp, pe, output_ptr);
}


/*
json null read
*/

static ierror_loc_t INLINE json_try_read_null (char **pp, char *pe, ibool_t *was_null_ptr)
{
    static const uint32_t null_bits = 0x000000006c6c756e; /* "null" */

    char *p = *pp;

    uint32_t next4 = *(uint32_t *)p;

    if (next4 != null_bits) {
        *was_null_ptr = ifalse;
        return 0;
    }

    *was_null_ptr = itrue;
    *pp           = p + sizeof ("null") - 1;

    return 0;
}


/*
string read/write
*/

static ierror_loc_t INLINE text_read_istring (imempool_t *pool, char **pp, char *pe, istring_t *output_ptr)
{
    char *p = *pp;

    size_t output_size = pe - p + 1;
    char  *output      = imempool_alloc (pool, output_size);

    output[output_size] = 0;
    memcpy (output, p, output_size - 1);

    *output_ptr = output;
    *pp         = p + output_size - 1;

    return 0;
}

static ierror_loc_t INLINE json_read_istring (imempool_t *pool, char **pp, char *pe, istring_t *output_ptr)
{
    char *p = *pp;

    if (*p++ != '"')
        return ierror_loc_format (*pp, *pp, "string missing opening quote");

    char *quote_ptr = memchr (p, '"', pe - p);

    if (!quote_ptr)
        return ierror_loc_format (p, pe, "string missing closing quote");

    size_t output_size = quote_ptr - p + 1;
    char  *output      = imempool_alloc (pool, output_size);

    output[output_size] = 0;
    memcpy (output, p, output_size - 1);

    *output_ptr = output;
    *pp         = quote_ptr + 1;

    return 0;
}


/*
time read/write
*/

static ierror_loc_t INLINE fixed_read_itime (const char *p, const size_t size, itime_t *output_ptr)
{
    const size_t size0 = size + 1;

                               /* p + 0123456789 */
    const size_t date_only = sizeof ("yyyy-mm-dd");

    if (date_only == size0 &&
        text_is_digit (p[0]) &&
        text_is_digit (p[1]) &&
        text_is_digit (p[2]) &&
        text_is_digit (p[3]) &&
                '-' == p[4]  &&
        text_is_digit (p[5]) &&
        text_is_digit (p[6]) &&
                '-' == p[7]  &&
        text_is_digit (p[8]) &&
        text_is_digit (p[9])) {

        const iint_t year  = (p[0] - '0') * 1000
                           + (p[1] - '0') * 100
                           + (p[2] - '0') * 10
                           + (p[3] - '0');

        const iint_t month = (p[5] - '0') * 10
                           + (p[6] - '0');

        const iint_t day   = (p[8] - '0') * 10
                           + (p[9] - '0');

        *output_ptr = itime_from_gregorian (year, month, day, 0, 0, 0);
        return 0;
    }

                               /* p + 01234567890123456789 */
    const size_t date_time = sizeof ("yyyy-mm-ddThh:mm:ssZ");

    if (date_time == size0 &&
        text_is_digit (p[ 0]) &&
        text_is_digit (p[ 1]) &&
        text_is_digit (p[ 2]) &&
        text_is_digit (p[ 3]) &&
                '-' == p[ 4]  &&
        text_is_digit (p[ 5]) &&
        text_is_digit (p[ 6]) &&
                '-' == p[ 7]  &&
        text_is_digit (p[ 8]) &&
        text_is_digit (p[ 9]) &&
                'T' == p[10]  &&
        text_is_digit (p[11]) &&
        text_is_digit (p[12]) &&
                ':' == p[13]  &&
        text_is_digit (p[14]) &&
        text_is_digit (p[15]) &&
                ':' == p[16]  &&
        text_is_digit (p[17]) &&
        text_is_digit (p[18]) &&
                'Z' == p[19] ) {

        const iint_t year   = (p[ 0] - '0') * 1000
                            + (p[ 1] - '0') * 100
                            + (p[ 2] - '0') * 10
                            + (p[ 3] - '0');

        const iint_t month  = (p[ 5] - '0') * 10
                            + (p[ 6] - '0');

        const iint_t day    = (p[ 8] - '0') * 10
                            + (p[ 9] - '0');

        const iint_t hour   = (p[11] - '0') * 10
                            + (p[12] - '0');

        const iint_t minute = (p[14] - '0') * 10
                            + (p[15] - '0');

        const iint_t second = (p[17] - '0') * 10
                            + (p[18] - '0');

        *output_ptr = itime_from_gregorian (year, month, day, hour, minute, second);
        return 0;
    }

    return ierror_loc_format (p + size - 1, p, "unknown time format, must be \"yyyy-mm-dd\" or \"yyyy-mm-ddThh:mm:ssZ\"");
}

static ierror_loc_t INLINE text_read_itime (char **pp, char *pe, itime_t *output_ptr)
{
    char  *p    = *pp;
    size_t size = pe - p;

    ierror_loc_t error = fixed_read_itime (p, size, output_ptr);
    if (error) return error;

    *pp = pe;

    return 0;
}

static ierror_loc_t INLINE json_read_itime (char **pp, char *pe, itime_t *output_ptr)
{
    char *p = *pp;

    if (*p++ != '"')
        return ierror_loc_format (*pp, *pp, "time missing opening quote");

    char *quote_ptr = memchr (p, '"', pe - p);

    if (!quote_ptr)
        return ierror_loc_format (p, pe, "time missing closing quote");

    size_t size = quote_ptr - p;

    ierror_loc_t error = fixed_read_itime (p, size, output_ptr);
    if (error) return error;

    *pp = quote_ptr + 1;

    return 0;
}

const size_t text_itime_max_size = sizeof ("yyyy-mm-ddThh:mm:ssZ");

static size_t INLINE text_write_itime (itime_t value, char *p)
{
    iint_t year, month, day, hour, minute, second;
    itime_to_gregorian (value, &year, &month, &day, &hour, &minute, &second);

    snprintf ( p, text_itime_max_size
             , "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ"
             , year, month, day, hour, minute, second );

    /* don't include the null-termination as part of the written size */
    return text_itime_max_size - 1;
}
